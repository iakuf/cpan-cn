package Mojo::Reactor;
use Mojo::Base 'Mojo::EventEmitter';

use Carp 'croak';
use Mojo::Loader 'load_class';

sub again { croak 'Method "again" not implemented by subclass' }

sub detect {
  my $try = $ENV{MOJO_REACTOR} || 'Mojo::Reactor::EV';
  return load_class($try) ? 'Mojo::Reactor::Poll' : $try;
}

sub io         { croak 'Method "io" not implemented by subclass' }
sub is_running { croak 'Method "is_running" not implemented by subclass' }

sub next_tick { shift->timer(0 => @_) and return undef }

sub one_tick  { croak 'Method "one_tick" not implemented by subclass' }
sub recurring { croak 'Method "recurring" not implemented by subclass' }
sub remove    { croak 'Method "remove" not implemented by subclass' }
sub reset     { croak 'Method "reset" not implemented by subclass' }
sub start     { croak 'Method "start" not implemented by subclass' }
sub stop      { croak 'Method "stop" not implemented by subclass' }
sub timer     { croak 'Method "timer" not implemented by subclass' }
sub watch     { croak 'Method "watch" not implemented by subclass' }

1;

=encoding utf8

=head1 NAME

Mojo::Reactor - 低级别事件反应器的基类 

=head1 SYNOPSIS

  package Mojo::Reactor::MyEventLoop;
  use Mojo::Base 'Mojo::Reactor';

  sub again      {...}
  sub io         {...}
  sub is_running {...}
  sub one_tick   {...}
  sub recurring  {...}
  sub remove     {...}
  sub reset      {...}
  sub start      {...}
  sub stop       {...}
  sub timer      {...}
  sub watch      {...}

=head1 DESCRIPTION

L<Mojo::Reactor> 是一个低级别事件反应堆的抽象出来的基类, 象 L<Mojo::Reactor::EV> 和 L<Mojo::Reactor::Poll>.

=head1 EVENTS

L<Mojo::Reactor> 继承全部的 L<Mojo::EventEmitter> 的事件并可以使用下面这些.

=head2 error

  $reactor->on(error => sub {
    my ($reactor, $err) = @_;
    ...
  });

如果是未处理的致命异常, 会调用这个错误回调. 需要注意的是, 如果本次事件是未处理或失败, 可能会杀死你的程序, 所以你需要小心.

  $reactor->on(error => sub {
    my ($reactor, $err) = @_;
    say "Something very bad happened: $err";
  });

=head1 METHODS

L<Mojo::Reactor> 继承全部的 L<Mojo::EventEmitter> 的方法并实现了下面这些.

=head2 again

  $reactor->again($id);

重启 timer. 意味着要重载的子类. 注意, 此方法需要一个活的 timer.

=head2 detect

  my $class = Mojo::Reactor->detect;

用于发现和检查最合适的可用的事件反应堆. 会尝试 C<MOJO_REACTOR> 环境变量中的值, 比如 L<Mojo::Reactor::EV> 或者 L<Mojo::Reactor::Poll>.

  # 最好的实例化中可用的事件反应堆
  my $reactor = Mojo::Reactor->detect->new;

=head2 io

  $reactor = $reactor->io($handle => sub {...});

监控 I/O 句柄事件, 当事件是可读或者可写的时候, 调用回调.
需要重载的子类.

  # 回调将被调用两次，如果句柄即可读取或者写入
  $reactor->io($handle => sub {
    my ($reactor, $writable) = @_;
    say $writable ? 'Handle is writable' : 'Handle is readable';
  });

=head2 is_running

  my $bool = $reactor->is_running;

检查反应堆是否运行. 

=head2 next_tick

  my $undef = $reactor->next_tick(sub {...});

尽快调用回调, 如果没有返回之前会返回 C<undef>.

=head2 one_tick

  $reactor->one_tick;

运行反应堆直到有事件发行. 注意这方法可以递归回反应堆, 所以你需要小心.

  # Don't block longer than 0.5 seconds
  my $id = $reactor->timer(0.5 => sub {});
  $reactor->one_tick;
  $reactor->remove($id);

=head2 recurring

  my $id = $reactor->recurring(0.25 => sub {...});

创建一个循环的 timer, 在指定的间隔时间调用回调.

=head2 remove

  my $bool = $reactor->remove($handle);
  my $bool = $reactor->remove($id);

删除句柄或者 timer.

=head2 reset

  $reactor->reset;

删除全部的句柄或者 timer.

=head2 start

  $reactor->start;

开始监控 I/O 和 timer 事件, 这会阻塞直到 L</"stop"> 被调用. 注意有些反应堆是会在没事件的时候自动停止的.

  # 只有当它尚未运行的时候, 启动反应堆
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

  # 监控只读事件
  $reactor->watch($handle, 1, 0);

  # 监控写事件
  $reactor->watch($handle, 0, 1);

  # 监控可读和可写
  $reactor->watch($handle, 1, 1);

  # 停止监控事件 
  $reactor->watch($handle, 0, 0);

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
