# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Mailer;

use 5.14.0;
use strict;
use warnings;

use parent qw(Exporter);
@Bugzilla::Mailer::EXPORT = qw(MessageToMTA build_thread_marker generate_email);

use Bugzilla::Constants;
use Bugzilla::Error;
use Bugzilla::Hook;
use Bugzilla::MIME;
use Bugzilla::User;
use Bugzilla::Util;

use Date::Format qw(time2str);

use Email::Sender::Simple qw(sendmail);
use Email::Sender::Transport::SMTP::Persistent;
use Bugzilla::Sender::Transport::Sendmail;

sub generate_email {
  my ($vars, $templates) = @_;
  my ($lang, $email_format, $msg_text, $msg_html, $msg_header);

  if ($vars->{to_user}) {
    $lang         = $vars->{to_user}->setting('lang');
    $email_format = $vars->{to_user}->setting('email_format');
  }
  else {
    # If there are users in the CC list who don't have an account,
    # use the default language for email notifications.
    $lang = Bugzilla::User->new()->setting('lang');

    # However we cannot fall back to the default email_format, since
    # it may be HTML, and many of the includes used in the HTML
    # template require a valid user object. Instead we fall back to
    # the plaintext template.
    $email_format = 'text_only';
  }

  my $template = Bugzilla->template_inner($lang);

  $template->process($templates->{header}, $vars, \$msg_header)
    || ThrowTemplateError($template->error());
  $template->process($templates->{text}, $vars, \$msg_text)
    || ThrowTemplateError($template->error());

  my @parts = (Bugzilla::MIME->create(
    attributes => {
      content_type => 'text/plain',
      charset      => 'UTF-8',
      encoding     => 'quoted-printable',
    },
    body_str => $msg_text,
  ));
  if ($templates->{html} && $email_format eq 'html') {
    $template->process($templates->{html}, $vars, \$msg_html)
      || ThrowTemplateError($template->error());
    push @parts,
      Bugzilla::MIME->create(
      attributes => {
        content_type => 'text/html',
        charset      => 'UTF-8',
        encoding     => 'quoted-printable',
      },
      body_str => $msg_html,
      );
  }

  my $email = Bugzilla::MIME->new($msg_header);
  # If there's only one part, we don't need to set the overall content type
  # because Email::MIME will automatically take it from that part (bug 1657496)
  if (scalar(@parts) > 1) {
    $email->content_type_set('multipart/alternative');

    # Some mail clients need same encoding for each part, even empty ones.
    $email->charset_set('UTF-8');
  }
  $email->parts_set(\@parts);
  return $email;
}

sub MessageToMTA {
  my ($msg, $send_now) = (@_);
  my $method = Bugzilla->params->{'mail_delivery_method'};
  return if $method eq 'None';

  if ( Bugzilla->params->{'use_mailer_queue'}
    && !$send_now
    && !Bugzilla->dbh->bz_in_transaction())
  {
    Bugzilla->job_queue->insert('send_mail', {msg => $msg});
    return;
  }

  my $dbh = Bugzilla->dbh;

  my $email = ref($msg) ? $msg : Bugzilla::MIME->new($msg);

  # If we're called from within a transaction, we don't want to send the
  # email immediately, in case the transaction is rolled back. Instead we
  # insert it into the mail_staging table, and bz_commit_transaction calls
  # send_staged_mail() after the transaction is committed.
  if (!$send_now && $dbh->bz_in_transaction()) {

    # The e-mail string may contain tainted values.
    my $string = $email->as_string;
    trick_taint($string);

    my $sth = $dbh->prepare("INSERT INTO mail_staging (message) VALUES (?)");
    $sth->bind_param(1, $string, $dbh->BLOB_TYPE);
    $sth->execute;
    return;
  }

  # Ensure that we are not sending emails too quickly to recipients.
  if (Bugzilla->params->{use_mailer_queue}
    && (EMAIL_LIMIT_PER_MINUTE || EMAIL_LIMIT_PER_HOUR))
  {
    $dbh->do("DELETE FROM email_rates WHERE message_ts < "
        . $dbh->sql_date_math('LOCALTIMESTAMP(0)', '-', '1', 'HOUR'));

    my $recipient = $email->header('To');

    if (EMAIL_LIMIT_PER_MINUTE) {
      my $minute_rate = $dbh->selectrow_array(
        "SELECT COUNT(*)
                   FROM email_rates
                  WHERE recipient = ?  AND message_ts >= "
          . $dbh->sql_date_math('LOCALTIMESTAMP(0)', '-', '1', 'MINUTE'), undef,
        $recipient
      );
      if ($minute_rate >= EMAIL_LIMIT_PER_MINUTE) {
        die EMAIL_LIMIT_EXCEPTION;
      }
    }
    if (EMAIL_LIMIT_PER_HOUR) {
      my $hour_rate = $dbh->selectrow_array(
        "SELECT COUNT(*)
                   FROM email_rates
                  WHERE recipient = ?  AND message_ts >= "
          . $dbh->sql_date_math('LOCALTIMESTAMP(0)', '-', '1', 'HOUR'), undef,
        $recipient
      );
      if ($hour_rate >= EMAIL_LIMIT_PER_HOUR) {
        die EMAIL_LIMIT_EXCEPTION;
      }
    }
  }

  my $from = $email->header('From');

  my $hostname;
  my $transport;
  if ($method eq "Sendmail") {
    if (ON_WINDOWS) {
      $transport
        = Bugzilla::Sender::Transport::Sendmail->new({sendmail => SENDMAIL_EXE});
    }
    else {
      $transport = Bugzilla::Sender::Transport::Sendmail->new();
    }
  }
  else {
    # Sendmail will automatically append our hostname to the From
    # address, but other mailers won't.
    my $urlbase = Bugzilla->params->{'urlbase'};
    $urlbase =~ m|//([^:/]+)[:/]?|;
    $hostname = $1 || 'localhost';
    $from .= "\@$hostname" if $from !~ /@/;
    $email->header_set('From', $from);

    # Sendmail adds a Date: header also, but others may not.
    if (!defined $email->header('Date')) {
      $email->header_set('Date', time2str("%a, %d %b %Y %T %z", time()));
    }
  }

  if ($method eq "SMTP") {
    my ($host, $port) = split(/:/, Bugzilla->params->{'smtpserver'}, 2);
    $transport = Bugzilla->request_cache->{smtp}
      //= Email::Sender::Transport::SMTP::Persistent->new({
      host => $host,
      defined($port) ? (port => $port) : (),
      sasl_username => Bugzilla->params->{'smtp_username'},
      sasl_password => Bugzilla->params->{'smtp_password'},
      helo          => $hostname,
      ssl           => Bugzilla->params->{'smtp_ssl'},
      debug         => Bugzilla->params->{'smtp_debug'}
      });
  }

  Bugzilla::Hook::process('mailer_before_send', {email => $email});

  return if $email->header('to') eq '';

  if ($method eq "Test") {
    my $filename = bz_locations()->{'datadir'} . '/mailer.testfile';
    open TESTFILE, '>>:encoding(UTF-8)', $filename;

    # From - <date> is required to be a valid mbox file.
    print TESTFILE "\n\nFrom - "
      . $email->header('Date') . "\n"
      . $email->as_string;
    close TESTFILE;
  }
  else {
    # This is useful for Sendmail, so we put it out here.
    local $ENV{PATH} = SENDMAIL_PATH;
    eval { sendmail($email, {transport => $transport}) };
    if ($@) {
      ThrowCodeError('mail_send_error', {msg => $@->message, mail => $email});
    }
  }

  # insert into email_rates
  if (Bugzilla->params->{use_mailer_queue}
    && (EMAIL_LIMIT_PER_MINUTE || EMAIL_LIMIT_PER_HOUR))
  {
    $dbh->do(
      "INSERT INTO email_rates(recipient, message_ts) VALUES (?, LOCALTIMESTAMP(0))",
      undef, $email->header('To')
    );
  }
}

# Builds header suitable for use as a threading marker in email notifications
sub build_thread_marker {
  my ($bug_id, $user_id, $is_new) = @_;

  if (!defined $user_id) {
    $user_id = Bugzilla->user->id;
  }

  my $sitespec = '@' . Bugzilla->params->{'urlbase'};
  $sitespec =~ s/:\/\//\./;    # Make the protocol look like part of the domain
  $sitespec =~ s/^([^:\/]+):(\d+)/$1/;    # Remove a port number, to relocate
  if ($2) {
    $sitespec = "-$2$sitespec";    # Put the port number back in, before the '@'
  }

  my $threadingmarker;
  if ($is_new) {
    $threadingmarker = "Message-ID: <bug-$bug_id-$user_id$sitespec>";
  }
  else {
    my $rand_bits = generate_random_password(10);
    $threadingmarker
      = "Message-ID: <bug-$bug_id-$user_id-$rand_bits$sitespec>"
      . "\nIn-Reply-To: <bug-$bug_id-$user_id$sitespec>"
      . "\nReferences: <bug-$bug_id-$user_id$sitespec>";
  }

  return $threadingmarker;
}

sub send_staged_mail {
  my $dbh = Bugzilla->dbh;

  my $emails = $dbh->selectall_arrayref('SELECT id, message FROM mail_staging');
  my $sth    = $dbh->prepare('DELETE FROM mail_staging WHERE id = ?');

  foreach my $email (@$emails) {
    my ($id, $message) = @$email;
    MessageToMTA($message);
    $sth->execute($id);
  }
}

1;

__END__

=head1 NAME

Bugzilla::Mailer - Provides methods for sending email

=head1 METHODS

=over

=item C<generate_email>

Generates a multi-part email message, using the supplied list of templates.

=item C<MessageToMTA>

Sends the passed message to the mail transfer agent.

The actual behaviour depends on a number of factors: if called from within a
database transaction, the message will be staged and sent when the transaction
is committed.  If email queueing is enabled, the message will be sent to
TheSchwartz job queue where it will be processed by the jobqueue daemon, else
the message is sent immediately.

=item C<build_thread_marker>

Builds header suitable for use as a threading marker in email notifications.

=item C<send_staged_mail>

Sends all staged messages -- called after a database transaction is committed.

=back
