package Minion;
use Mojo::Base 'Mojo::EventEmitter';

use Carp 'croak';
use Minion::Job;
use Minion::Worker;
use Mojo::Loader;
use Mojo::Server;
use Mojo::URL;
use Scalar::Util 'weaken';

has app => sub { Mojo::Server->new->build_app('Mojo::HelloWorld') };
has 'backend';
has remove_after => 864000;
has tasks => sub { {} };

our $VERSION = '0.33';

sub add_task {
  my ($self, $name, $cb) = @_;
  $self->tasks->{$name} = $cb;
  return $self;
}

sub enqueue {
  my $self = shift;
  my $cb = ref $_[-1] eq 'CODE' ? pop : undef;

  # Blocking
  return $self->backend->enqueue(@_) unless $cb;

  # Non-blocking
  weaken $self;
  $self->backend->enqueue(@_ => sub { shift; $self->$cb(@_) });
}

sub job {
  my ($self, $id) = @_;

  return undef unless my $job = $self->backend->job_info($id);
  return Minion::Job->new(
    args   => $job->{args},
    id     => $job->{id},
    minion => $self,
    task   => $job->{task}
  );
}

sub new {
  my $self = shift->SUPER::new;

  my $class = 'Minion::Backend::' . shift;
  my $e     = Mojo::Loader->new->load($class);
  croak ref $e ? $e : qq{Backend "$class" missing} if $e;

  $self->backend($class->new(@_));
  weaken $self->backend->minion($self)->{minion};

  return $self;
}

sub perform_jobs {
  my $self   = shift;
  my $worker = $self->worker->register;
  while (my $job = $worker->dequeue(0)) { $job->perform }
  $worker->unregister;
}

sub repair { shift->_delegate('repair') }
sub reset  { shift->_delegate('reset') }

sub stats { shift->backend->stats }

sub worker {
  my $self = shift;
  my $worker = Minion::Worker->new(minion => $self);
  $self->emit(worker => $worker);
  return $worker;
}

sub _delegate {
  my ($self, $method) = @_;
  $self->backend->$method;
  return $self;
}

1;

=encoding utf8

=head1 NAME

Minion - Job queue

=head1 SYNOPSIS

  use Minion;

  # 连接到后端 
  my $minion = Minion->new(File  => '/Users/sri/minion.data');
  my $minion = Minion->new(Mango => 'mongodb://localhost:27017');

  # 添加作业 
  $minion->add_task(something_slow => sub {
    my ($job, @args) = @_;
    sleep 5;
    say 'This is a background worker process.';
  });

  # 入队 jobs
  $minion->enqueue(something_slow => ['foo', 'bar']);
  $minion->enqueue(something_slow => [1, 2, 3] => {priority => 5});

  # 执行测试工作
  $minion->enqueue(something_slow => ['foo', 'bar']);
  $minion->perform_jobs;

  # 构建更复杂的 worker
  my $worker = $minion->repair->worker->register;
  if (my $job = $worker->dequeue(5)) { $job->perform }
  $worker->unregister;

=head1 DESCRIPTION

L<Minion> 是一个基于 L<Mojolicious> 框架实现的任务队列服务并且支持多种后端.

变成后台 worker 进程通常是使用 L<Minion::Command::minion::worker> 的命令, 这个会自动的加载 L<Mojolicious::Plugin::Minion> 插件.

  $ ./myapp.pl minion worker

Jobs 可以直接通过 L<Minion::Command::minion::job> 的命令进行管理.

  $ ./myapp.pl minion job

注意这个是实验性的, 所以很有可能更改, 恕不警告!

大多接口的 API 并不会改变多少, 但是你如果想在生产环境中使用, 请等待稳定的 1.0 release.

=head1 EVENTS

L<Minion> 使用了全部的 L<Mojo::EventEmitter> 的事件并自己使用了下面这些.

=head2 worker

  $minion->on(worker => sub {
    my ($minion, $worker) = @_;
    ...
  });

当一个新的 worker 创建的时候激活这个订阅.

  $minion->on(worker => sub {
    my ($minion, $worker) = @_;
    my $id = $worker->id;
    say "Worker $$:$id started.";
  });

=head1 ATTRIBUTES

L<Minion> 实现了下列的属性. 

=head2 app

  my $app = $minion->app;
  $minion = $minion->app(MyApp->new);

队列应用, 默认的是 L<Mojo::HelloWorld> 对象.

=head2 backend

  my $backend = $minion->backend;
  $minion     = $minion->backend(Minion::Backend::File->new);

后端实现, 通常是 L<Minion::Backend::File> 或者 L<Minion::Backend::Mango> 对象.

=head2 remove_after

  my $after = $minion->remove_after;
  $minion   = $minion->remove_after(86400);

以时间秒为单位之后的 job , 已经变成了 C<finished> 状态的, 会被  L</"repair"> 自动的删除, 默认是 C<864000> (10 days).

=head2 tasks

  my $tasks = $minion->tasks;
  $minion   = $minion->tasks({foo => sub {...}});

Registered tasks.

=head1 METHODS

L<Minion> 使用了全部的 L<Mojo::EventEmitter> 方法, 并实现了下面的这些.

=head2 add_task

  $minion = $minion->add_task(foo => sub {...});

注册一个新的作业.

=head2 enqueue

  my $id = $minion->enqueue('foo');
  my $id = $minion->enqueue(foo => [@args]);
  my $id = $minion->enqueue(foo => [@args] => {priority => 1});

入队一个新的 C<inactive> 状态的 job . 你也可以使用回调的方式来实现无阻塞操作.

  $minion->enqueue(foo => sub {
    my ($minion, $err, $id) = @_;
    ...
  });
  Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

目前可供选择的选项:

=over 2

=item delay

  delay => 10

从现在开始, 延迟 job 指定的秒数.

=item priority

  priority => 5

作业优先级, 默认为 C<0>.

=back

=head2 job

  my $job = $minion->job($id);

得到 L<Minion::Job> 的对象, 但并不会改变任何实际的 job. 如果没有 job 就会返回 C<undef> .

=head2 new

  my $minion = Minion->new(File => '/Users/sri/minion.data');

构造一个新的 L<Minion> 对象.

=head2 perform_jobs

  $minion->perform_jobs;

进行所有作业, 测试时非常有用.

=head2 repair

  $minion = $minion->repair;

修复 worker 注册和 job 队列. 当执行这个方法时全部的进程和 worker 在这个主机上必须所有者都是相同的用户. 这能检查所有的 worker 是否还有活着的 signals.

=head2 reset

  $minion = $minion->reset;

Reset job queue.

=head2 stats

  my $stats = $minion->stats;

取得 worker 和 job 的统计信息.

=head2 worker

  my $worker = $minion->worker;

Build L<Minion::Worker> object.

=head1 AUTHOR

Sebastian Riedel, C<sri@cpan.org>.

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2014, Sebastian Riedel.

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

L<https://github.com/kraih/minion>, L<Mojolicious::Guides>,
L<http://mojolicio.us>.

=cut
