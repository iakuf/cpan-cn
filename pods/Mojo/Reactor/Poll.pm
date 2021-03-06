package Mojo::Reactor::Poll;
use Mojo::Base 'Mojo::Reactor';

use Carp 'croak';
use IO::Poll qw(POLLERR POLLHUP POLLIN POLLNVAL POLLOUT POLLPRI);
use List::Util 'min';
use Mojo::Util qw(md5_sum steady_time);
use Time::HiRes 'usleep';

sub again {
  croak 'Timer not active' unless my $timer = shift->{timers}{shift()};
  $timer->{time} = steady_time + $timer->{after};
}

sub io {
  my ($self, $handle, $cb) = @_;
  $self->{io}{fileno $handle} = {cb => $cb};
  return $self->watch($handle, 1, 1);
}

sub is_running { !!shift->{running} }

sub one_tick {
  my $self = shift;

  # Just one tick
  local $self->{running} = 1 unless $self->{running};

  # Wait for one event
  my $i;
  until ($i || !$self->{running}) {

    # Stop automatically if there is nothing to watch
    return $self->stop unless keys %{$self->{timers}} || keys %{$self->{io}};

    # Calculate ideal timeout based on timers and round up to next millisecond
    my $min = min map { $_->{time} } values %{$self->{timers}};
    my $timeout = defined $min ? $min - steady_time : 0.5;
    $timeout = $timeout <= 0 ? 0 : int($timeout * 1000) + 1;

    # I/O
    if (keys %{$self->{io}}) {
      my @poll = map { $_ => $self->{io}{$_}{mode} } keys %{$self->{io}};

      # This may break in the future, but is worth it for performance
      if (IO::Poll::_poll($timeout, @poll) > 0) {
        while (my ($fd, $mode) = splice @poll, 0, 2) {

          if ($mode & (POLLIN | POLLPRI | POLLNVAL | POLLHUP | POLLERR)) {
            next unless my $io = $self->{io}{$fd};
            ++$i and $self->_try('I/O watcher', $io->{cb}, 0);
          }
          next unless $mode & POLLOUT && (my $io = $self->{io}{$fd});
          ++$i and $self->_try('I/O watcher', $io->{cb}, 1);
        }
      }
    }

    # Wait for timeout if poll can't be used
    elsif ($timeout) { usleep $timeout * 1000 }

    # Timers (time should not change in between timers)
    my $now = steady_time;
    for my $id (keys %{$self->{timers}}) {
      next unless my $t = $self->{timers}{$id};
      next unless $t->{time} <= $now;

      # Recurring timer
      if (exists $t->{recurring}) { $t->{time} = $now + $t->{recurring} }

      # Normal timer
      else { $self->remove($id) }

      ++$i and $self->_try('Timer', $t->{cb}) if $t->{cb};
    }
  }
}

sub recurring { shift->_timer(1, @_) }

sub remove {
  my ($self, $remove) = @_;
  return !!delete $self->{timers}{$remove} unless ref $remove;
  return !!delete $self->{io}{fileno $remove};
}

sub reset { delete @{shift()}{qw(io timers)} }

sub start {
  my $self = shift;
  $self->{running}++;
  $self->one_tick while $self->{running};
}

sub stop { delete shift->{running} }

sub timer { shift->_timer(0, @_) }

sub watch {
  my ($self, $handle, $read, $write) = @_;

  croak 'I/O watcher not active' unless my $io = $self->{io}{fileno $handle};
  $io->{mode} = 0;
  $io->{mode} |= POLLIN | POLLPRI if $read;
  $io->{mode} |= POLLOUT if $write;

  return $self;
}

sub _id {
  my $self = shift;
  my $id;
  do { $id = md5_sum 't' . steady_time . rand 999 } while $self->{timers}{$id};
  return $id;
}

sub _timer {
  my ($self, $recurring, $after, $cb) = @_;

  my $id    = $self->_id;
  my $timer = $self->{timers}{$id}
    = {cb => $cb, after => $after, time => steady_time + $after};
  $timer->{recurring} = $after if $recurring;

  return $id;
}

sub _try {
  my ($self, $what, $cb) = (shift, shift, shift);
  eval { $self->$cb(@_); 1 } or $self->emit(error => "$what failed: $@");
}

1;

=encoding utf8

=head1 NAME

Mojo::Reactor::Poll - poll 实现的事件反应堆

=head1 SYNOPSIS

  use Mojo::Reactor::Poll;

  # Watch if handle becomes readable or writable
  my $reactor = Mojo::Reactor::Poll->new;
  $reactor->io($first => sub {
    my ($reactor, $writable) = @_;
    say $writable ? 'First handle is writable' : 'First handle is readable';
  });

  # Change to watching only if handle becomes writable
  $reactor->watch($first, 0, 1);

  # Turn file descriptor into handle and watch if it becomes readable
  my $second = IO::Handle->new_from_fd($fd, 'r');
  $reactor->io($second => sub {
    my ($reactor, $writable) = @_;
    say $writable ? 'Second handle is writable' : 'Second handle is readable';
  })->watch($second, 1, 0);

  # Add a timer
  $reactor->timer(15 => sub {
    my $reactor = shift;
    $reactor->remove($first);
    $reactor->remove($second);
    say 'Timeout!';
  });

  # Start reactor if necessary
  $reactor->start unless $reactor->is_running;

=head1 DESCRIPTION

L<Mojo::Reactor::Poll> 是一个低级别的基于 L<IO::Poll> 实现的事件反应堆.

=head1 EVENTS

L<Mojo::Reactor::Poll> 继承全部的 L<Mojo::Reactor> 的事件.

=head1 METHODS

L<Mojo::Reactor::Poll> 继承全部的 L<Mojo::Reactor> 的方法, 并实现了下面这些.

=head2 again

  $reactor->again($id);

重启 timer. 注意, 此方法需要一个活动的 timer.

=head2 io

  $reactor = $reactor->io($handle => sub {...});

监控 I/O 句柄事件, 当事件是可读或者可写的时候, 调用回调. 

  # Callback will be invoked twice if handle becomes readable and writable
  $reactor->io($handle => sub {
    my ($reactor, $writable) = @_;
    say $writable ? 'Handle is writable' : 'Handle is readable';
  });

=head2 is_running

  my $bool = $reactor->is_running;

检查反应堆是否运行.

=head2 one_tick

  $reactor->one_tick;

运行反应堆直到有事件发行, 如果没有事件监控会在次运行反应堆. 注意这方法可以递归回反应堆, 所以你需要小心.

  # Don't block longer than 0.5 seconds
  my $id = $reactor->timer(0.5 => sub {});
  $reactor->one_tick;
  $reactor->remove($id);

=head2 recurring

  my $id = $reactor->recurring(0.25 => sub {...});

创建一个新的循环的 timer, 在指定的间隔时间调用回调.

=head2 remove

  my $bool = $reactor->remove($handle);
  my $bool = $reactor->remove($id);

删除句柄或者 timer.

=head2 reset

  $reactor->reset;

删除全部的句柄或者 timer.

=head2 start

  $reactor->start;

开始监控 I/O 和 timer 事件, 这会阻塞直到 L<"/stop"> 被调用. 注意有些反应堆是会在没事件的时候自动停止的.

  # Start reactor only if it is not running already
  $reactor->start unless $reactor->is_running;

=head2 stop

  $reactor->stop;

停止监控 I/O 和 timer 事件.

=head2 timer

  my $id = $reactor->timer(0.5 => sub {...});

创建一个新的 timer. 在指定的时间后调用回调.

=head2 watch

  $reactor = $reactor->watch($handle, $readable, $writable);

对于 I/O 事件上创建监控, 指定 true 和 false 的值. 注意这需要一个活动的 I/O 监控者.

  # Watch only for readable events
  $reactor->watch($handle, 1, 0);

  # Watch only for writable events
  $reactor->watch($handle, 0, 1);

  # Watch for readable and writable events
  $reactor->watch($handle, 1, 1);

  # Pause watching for events
  $reactor->watch($handle, 0, 0);

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
