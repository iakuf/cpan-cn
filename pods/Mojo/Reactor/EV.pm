package Mojo::Reactor::EV;
use Mojo::Base 'Mojo::Reactor::Poll';

use Carp 'croak';
use EV 4.0;

my $EV;

sub CLONE { die "EV does not work with ithreads.\n" }

sub DESTROY { undef $EV }

sub again {
  croak 'Timer not active' unless my $timer = shift->{timers}{shift()};
  $timer->{watcher}->again;
}

sub is_running { !!EV::depth }

# We have to fall back to Mojo::Reactor::Poll, since EV is unique
sub new { $EV++ ? Mojo::Reactor::Poll->new : shift->SUPER::new }

sub one_tick { EV::run(EV::RUN_ONCE) }

sub recurring { shift->_timer(1, @_) }

sub start {EV::run}

sub stop { EV::break(EV::BREAK_ALL) }

sub timer { shift->_timer(0, @_) }

sub watch {
  my ($self, $handle, $read, $write) = @_;

  my $fd = fileno $handle;
  croak 'I/O watcher not active' unless my $io = $self->{io}{$fd};

  my $mode = 0;
  $mode |= EV::READ  if $read;
  $mode |= EV::WRITE if $write;

  if ($mode == 0) { delete $io->{watcher} }
  elsif (my $w = $io->{watcher}) { $w->events($mode) }
  else {
    my $cb = sub {
      my ($w, $revents) = @_;
      $self->_try('I/O watcher', $self->{io}{$fd}{cb}, 0)
        if EV::READ & $revents;
      $self->_try('I/O watcher', $self->{io}{$fd}{cb}, 1)
        if EV::WRITE & $revents && $self->{io}{$fd};
    };
    $io->{watcher} = EV::io($fd, $mode, $cb);
  }

  return $self;
}

sub _timer {
  my ($self, $recurring, $after, $cb) = @_;
  $after ||= 0.0001 if $recurring;

  my $id      = $self->_id;
  my $wrapper = sub {
    delete $self->{timers}{$id} unless $recurring;
    $self->_try('Timer', $cb);
  };
  EV::now_update() if $after > 0;
  $self->{timers}{$id}{watcher} = EV::timer($after, $after, $wrapper);

  return $id;
}

1;

=encoding utf8

=head1 NAME

Mojo::Reactor::EV - libev 实现的低级事件反应堆 

=head1 SYNOPSIS

  use Mojo::Reactor::EV;

  # Watch if handle becomes readable or writable
  my $reactor = Mojo::Reactor::EV->new;
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

L<Mojo::Reactor::EV> 是一个低级事件反应堆, 基于 L<EV> (4.0+).

=head1 EVENTS

L<Mojo::Reactor::EV> 继承 L<Mojo::Reactor::Poll> 全部的事件

=head1 METHODS

L<Mojo::Reactor::EV>  继承 L<Mojo::Reactor::Poll> 全部的方法, 并自己实现了下面的这些.

=head2 again

  $reactor->again($id);

重启 timer. 注意, 此方法需要一个活动的 timer.

=head2 is_running

  my $bool = $reactor->is_running;

检查反应堆是否运行.

=head2 new

  my $reactor = Mojo::Reactor::EV->new;

构造一个新的 L<Mojo::Reactor::EV> 对象.

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

对于 I/O 事件上创建句柄监控, 指定 true 和 false 的值. 注意这需要一个活动的 I/O 监控者.

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
