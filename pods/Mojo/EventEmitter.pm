package Mojo::EventEmitter;
use Mojo::Base -base;

use Scalar::Util qw(blessed weaken);

use constant DEBUG => $ENV{MOJO_EVENTEMITTER_DEBUG} || 0;

sub catch { $_[0]->on(error => $_[1]) and return $_[0] }

sub emit {
  my ($self, $name) = (shift, shift);

  if (my $s = $self->{events}{$name}) {
    warn "-- Emit $name in @{[blessed $self]} (@{[scalar @$s]})\n" if DEBUG;
    for my $cb (@$s) { $self->$cb(@_) }
  }
  else {
    warn "-- Emit $name in @{[blessed $self]} (0)\n" if DEBUG;
    die "@{[blessed $self]}: $_[0]" if $name eq 'error';
  }

  return $self;
}

sub emit_safe {
  my ($self, $name) = (shift, shift);

  if (my $s = $self->{events}{$name}) {
    warn "-- Emit $name in @{[blessed $self]} safely (@{[scalar @$s]})\n"
      if DEBUG;
    for my $cb (@$s) {
      $self->emit(error => qq{Event "$name" failed: $@})
        unless eval { $self->$cb(@_); 1 };
    }
  }
  else {
    warn "-- Emit $name in @{[blessed $self]} safely (0)\n" if DEBUG;
    die "@{[blessed $self]}: $_[0]" if $name eq 'error';
  }

  return $self;
}

sub has_subscribers { !!@{shift->subscribers(shift)} }

sub on {
  my ($self, $name, $cb) = @_;
  push @{$self->{events}{$name} ||= []}, $cb;
  return $cb;
}

sub once {
  my ($self, $name, $cb) = @_;

  weaken $self;
  my $wrapper;
  $wrapper = sub {
    $self->unsubscribe($name => $wrapper);
    $cb->(@_);
  };
  $self->on($name => $wrapper);
  weaken $wrapper;

  return $wrapper;
}

sub subscribers { shift->{events}{shift()} || [] }

sub unsubscribe {
  my ($self, $name, $cb) = @_;

  # One
  if ($cb) {
    $self->{events}{$name} = [grep { $cb ne $_ } @{$self->{events}{$name}}];
    delete $self->{events}{$name} unless @{$self->{events}{$name}};
  }

  # All
  else { delete $self->{events}{$name} }

  return $self;
}

1;

=encoding utf8

=head1 NAME

Mojo::EventEmitter - 事件发射器的基类

=head1 SYNOPSIS

  package Cat;
  use Mojo::Base 'Mojo::EventEmitter';

  # Emit events
  sub poke {
    my $self = shift;
    $self->emit(roar => 3);
  }

  package main;

  # Subscribe to events
  my $tiger = Cat->new;
  $tiger->on(roar => sub {
    my ($tiger, $times) = @_;
    say 'RAWR!' for 1 .. $times;
  });
  $tiger->poke;

=head1 DESCRIPTION

L<Mojo::EventEmitter> 是一个简单的用于事件对象的激发基类.

=head1 EVENTS

L<Mojo::EventEmitter> 可以激发下列的事件.

=head2 error

  $e->on(error => sub {
    my ($e, $err) = @_;
    ...
  });

如果没有处理, 就会激发错误事件.

  $e->on(error => sub {
    my ($e, $err) = @_;
    say "This looks bad: $err";
  });

=head1 METHODS

L<Mojo::EventEmitter> 包含全部的 L<Mojo::Base> 的方法, 并且实现了下列这些.

=head2 catch

  $e = $e->catch(sub {...});

订阅 ( Subscribe ) 到 L</"error"> 对象的事件.

  # Longer version
  $e->on(error => sub {...});

=head2 emit

  $e = $e->emit('foo');
  $e = $e->emit('foo', 123);

调用并激发事件. 译者注: 这个事件需要在其它的地方使用 on 的方式来订阅了才会执行这个过程. 

=head2 emit_safe

  $e = $e->emit_safe('foo');
  $e = $e->emit_safe('foo', 123);

安全的激发事件. 如果失败就会激发 L</"error"> 事件.

=head2 has_subscribers

  my $bool = $e->has_subscribers('foo');

检查如果事件是存在订阅者 ( subscribers ) 的, 返回值为真或者假.

=head2 on

  my $cb = $e->on(foo => sub {...});

订阅指定名字的事件对象. 

译者注: 比如上面就是订阅了 foo 的事件, 这时其它的地方调用 emit 来激发时就会使用这个函数.  这个 on 的订阅是可以重复订阅的, 这也是为什么这叫订阅, 不叫注册的原因.

  $e->on(foo => sub {
    my ($e, @args) = @_;
    ...
  });

=head2 once

  my $cb = $e->once(foo => sub {...});
  
先订阅事件, 激发一次事件后, 再次退订本次订阅的事件.

  $e->once(foo => sub {
    my ($e, @args) = @_;
    ...
  });

=head2 subscribers

  my $subscribers = $e->subscribers('foo');

得到所有的订阅者事件, 返回值是一个数组引用, 包含的先后顺序订阅的子函数引用.

  # Unsubscribe last subscriber
  $e->unsubscribe(foo => $e->subscribers('foo')->[-1]);

=head2 unsubscribe

  $e = $e->unsubscribe('foo');
  $e = $e->unsubscribe(foo => $cb);

退订掉指定名字的事件, 这时所有订阅进去的事件都会失效.

=head1 DEBUGGING

你可以设置 C<MOJO_EVENTEMITTER_DEBUG> 的环境变量来得到一些高级的事件调试信息. 这些信息会被输出到标准错误.

  MOJO_EVENTEMITTER_DEBUG=1

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
