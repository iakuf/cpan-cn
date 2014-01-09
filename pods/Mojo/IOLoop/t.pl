#!/usr/bin/perl
use strict;
use 5.010;
use Mojo::IOLoop::Delay;


# 顺序化多个事件
my $delay = Mojo::IOLoop::Delay->new;
$delay->steps(

  # First step (simple timer)
  sub {
    my $delay = shift;
    Mojo::IOLoop->timer(2 => $delay->begin);
    say 'Second step in 2 seconds.';
  },

  # Second step (parallel timers)
  sub {
    my ($delay, @args) = @_;
    Mojo::IOLoop->timer(1 => $delay->begin);
    Mojo::IOLoop->timer(3 => $delay->begin);
    say 'Third step in 3 seconds.';
  },

  # Third step (the end)
  sub {
    my ($delay, @args) = @_;
    say 'And done after 5 seconds total.';
  }
);
$delay->wait unless Mojo::IOLoop->is_running;
