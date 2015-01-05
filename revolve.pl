use Irssi;
use strict;
use Irssi::TextUI;
use vars qw($VERSION %IRSSI);

$VERSION = "0.0.2";
%IRSSI = (
    authors => 'Ryan Freebern',
    contact => 'ryan@freebern.org',
    name => 'revolve',
    description => 'Summarizes multiple sequential joins/parts/quits.',
    license => 'GPL v2 or later',
    url => 'http://github.com/rfreebern/irssi-revolving-door',
);

# Based on compact.pl by Wouter Coekaerts <wouter@coekaerts.be>
# http://wouter.coekaerts.be/irssi/scripts/compact.pl.html

my %summary_lines;
# Holds events for summary lines. For each entry in %summary_lines, there is a corresponding entry
# in %summary_lines_events with the following format:
# 'Joins' => Array of Nicks
# 'Parts' => Array of Nicks
# 'Nicks' => Array of "$oldnick -> $newnick"
# 'Modes' => Hash of modestring => Array of nicks, where modestring is something like +v
my %summary_lines_events;

sub print_summary_line {
    my %door = %{shift()};
    my ($window, $check) = @_;
    my @summarized = ();
    foreach my $part (qw/Joins Parts Quits Nicks/) {
        if (scalar @{$door{$part}}) {
            push @summarized, "\%W$part:\%n " . join(', ', @{$door{$part}});
        }
    }

    if (%{$door{'Modes'}}) {
        my @modestrings = map {$_ . ': ' . join(', ', @{$door{'Modes'}{$_}})} (keys %{$door{'Modes'}});
        push @summarized, "\%WModes:\%n " . join(' ', @modestrings);
    }

    my $summary = join(' -- ', @summarized);
    $window->print($summary, MSGLEVEL_NEVER);

    # Get the line we just printed so we can log its ID.
    my $view = $window->view();
    $view->set_bookmark_bottom('bottom');
    my $last = $view->get_bookmark('bottom');
    $summary_lines{$check} = $last->{'_irssi'};

    $view->redraw();
}

sub remove_message_and_summary_line {
    my ($window, $check) = @_;

    my $view = $window->view();

    $view->set_bookmark_bottom('bottom');
    my $last = $view->get_bookmark('bottom');
    my $secondlast = $last->prev();

    # Remove the last line, which should have the join/part/quit message.
    $view->remove_line($last);

    # If the second-to-last line is a summary line, parse it.
    if ($secondlast and %summary_lines and $secondlast->{'_irssi'} == $summary_lines{$check}) {
        $view->remove_line($secondlast);
    } else {
        delete $summary_lines_events{$check};
    }
}

sub handle_join {
    my %door = %{shift()};
    my ($nick) = @_;
    push(@{$door{'Joins'}}, $nick);
    @{$door{'Parts'}} = grep { $_ ne $nick } @{$door{'Parts'}} if (scalar @{$door{'Parts'}});
    @{$door{'Quits'}} = grep { $_ ne $nick } @{$door{'Quits'}} if (scalar @{$door{'Quits'}});
}

sub handle_quit {
    my %door = %{shift()};
    my ($nick) = @_;
    push(@{$door{'Quits'}}, $nick) if (!grep(/^\Q$nick\E$/, @{$door{'Joins'}}));
    @{$door{'Joins'}} = grep { $_ ne $nick } @{$door{'Joins'}} if (scalar @{$door{'Joins'}});
}

sub handle_part {
    my %door = %{shift()};
    my ($nick) = @_;
    push(@{$door{'Parts'}}, $nick) if (!grep(/^\Q$nick\E$/, @{$door{'Joins'}}));
    @{$door{'Joins'}} = grep { $_ ne $nick } @{$door{'Joins'}} if (scalar @{$door{'Joins'}});
}

sub handle_nick {
    my %door = %{shift()};
    my ($nick, $new_nick) = @_;
    my $nick_found = 0;
    foreach my $known_nick (@{$door{'Nicks'}}) {
        my ($orig_nick, $current_nick) = split(/ -> /, $known_nick);
        if ($new_nick eq $orig_nick) { # Changed nickname back to original.
            @{$door{'Nicks'}} = grep { $_ ne "$orig_nick -> $current_nick" } @{$door{'Nicks'}};
            $nick_found = 1;
            last;
        } elsif ($current_nick eq $nick) {
            $_ =~ s/\b\Q$current_nick\E\b/$new_nick/ foreach @{$door{'Nicks'}};
            $nick_found = 1;
            last;
        }
    }
    if (!$nick_found) {
        push(@{$door{'Nicks'}}, "$nick -> $new_nick");
    }
    # Update nicks in join/part/quit lists.
    foreach my $part (qw/Joins Parts Quits/) {
        $_ =~ s/\b\Q$nick\E\b/$new_nick/ foreach @{$door{$part}};
    }

    foreach my $mode (keys %{$door{'Modes'}}) {
        $_ =~ s/\b\Q$nick\E\b/$new_nick/ foreach @{$door{'Modes'}{$mode}};
    }
}

sub handle_mode {
    my %events = %{shift()};
    my ($mode, $nick) = @_;
    if (not exists($events{'Modes'}{$mode})) {
        $events{'Modes'}{$mode} = [];
    }
    push(@{$events{'Modes'}{$mode}}, $nick);
}

sub summarize {
    my ($server, $channel, $handler, @handler_args) = @_;

    my $window = $server->window_find_item($channel);
    return if (!$window);
    my $check = $server->{tag} . ':' . $channel;

    remove_message_and_summary_line($window, $check);

    my %events = ('Joins' => [], 'Parts' => [], 'Quits' => [], 'Nicks' => [], 'Modes' => {});
    if (exists $summary_lines_events{$check}) {
        %events = %{$summary_lines_events{$check}};
    }

    $handler->(\%events, @handler_args);

    print_summary_line(\%events, $window, $check);
    $summary_lines_events{$check} = \%events;
}

sub summarize_join {
    my ($server, $channel, $nick, $address, $reason) = @_;
    &summarize($server, $channel, \&handle_join, $nick);
}

sub summarize_quit {
    my ($server, $nick, $address, $reason) = @_;
    my @channels = $server->channels();
    foreach my $channel (@channels) {
        my $window = $server->window_find_item($channel->{name});
        next if (!$window);
        my $view = $window->view();
        $view->set_bookmark_bottom('bottom');
        my $last = $view->get_bookmark('bottom');
        my $last_text = $last->get_text(1);
        if ($last_text =~ m/\Q$nick\E.*?has quit/) {
            &summarize($server, $channel->{name}, \&handle_quit, $nick);
        }
    }
}

sub summarize_part {
    my ($server, $channel, $nick, $address, $reason) = @_;
    &summarize($server, $channel, \&handle_part, $nick);
}

sub summarize_nick {
    my ($server, $new_nick, $old_nick, $address) = @_;
    my @channels = $server->channels();
    foreach my $channel (@channels) {
        my $channel_nick = $channel->nick_find($new_nick);
        if (defined $channel_nick) {
            &summarize($server, $channel->{name}, \&handle_nick, $old_nick, $new_nick);
        }
    }
}

sub summarize_mode {
    my ($channel, $nick, $setby, $mode, $type) = @_;
    if ($mode eq '+') {$mode = 'v'}
    &summarize($channel->{server}, $channel->{name}, \&handle_mode, $type . $mode, $nick->{nick});
}

Irssi::signal_add_priority('message join', \&summarize_join, Irssi::SIGNAL_PRIORITY_LOW + 1);
Irssi::signal_add_priority('message part', \&summarize_part, Irssi::SIGNAL_PRIORITY_LOW + 1);
Irssi::signal_add_priority('message quit', \&summarize_quit, Irssi::SIGNAL_PRIORITY_LOW + 1);
Irssi::signal_add_priority('message nick', \&summarize_nick, Irssi::SIGNAL_PRIORITY_LOW + 1);
Irssi::signal_add_priority('nick mode changed', \&summarize_mode, Irssi::SIGNAL_PRIORITY_LOW + 1);
