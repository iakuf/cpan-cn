package Mojolicious;
use Mojo::Base 'Mojo';

# "Fry: Shut up and take my money!"
use Carp 'croak';
use Mojo::Exception;
use Mojolicious::Commands;
use Mojolicious::Controller;
use Mojolicious::Plugins;
use Mojolicious::Renderer;
use Mojolicious::Routes;
use Mojolicious::Sessions;
use Mojolicious::Static;
use Mojolicious::Types;
use Scalar::Util qw(blessed weaken);

has commands => sub {
  my $commands = Mojolicious::Commands->new(app => shift);
  weaken $commands->{app};
  return $commands;
};
has controller_class => 'Mojolicious::Controller';
has mode => sub { $ENV{MOJO_MODE} || 'development' };
has plugins  => sub { Mojolicious::Plugins->new };
has renderer => sub { Mojolicious::Renderer->new };
has routes   => sub { Mojolicious::Routes->new };
has secret   => sub {
  my $self = shift;

  # Warn developers about insecure default
  $self->log->debug('Your secret passphrase needs to be changed!!!');

  # Default to application name
  return ref $self;
};
has sessions => sub { Mojolicious::Sessions->new };
has static   => sub { Mojolicious::Static->new };
has types    => sub { Mojolicious::Types->new };

our $CODENAME = 'Rainbow';
our $VERSION  = '3.54';

sub AUTOLOAD {
  my $self = shift;

  # Method
  my ($package, $method) = our $AUTOLOAD =~ /^([\w:]+)::(\w+)$/;
  croak "Undefined subroutine &${package}::$method called"
    unless blessed $self && $self->isa(__PACKAGE__);

  # Check for helper
  croak qq{Can't locate object method "$method" via package "$package"}
    unless my $helper = $self->renderer->helpers->{$method};

  # Call helper with fresh controller
  return $self->controller_class->new(app => $self)->$helper(@_);
}

sub DESTROY { }

sub new {
  my $self = shift->SUPER::new(@_);

  # Paths
  my $home = $self->home;
  push @{$self->renderer->paths}, $home->rel_dir('templates');
  push @{$self->static->paths},   $home->rel_dir('public');

  # Default to application namespace
  my $r = $self->routes->namespace(ref $self);

  # Hide controller attributes/methods and "handler"
  $r->hide(qw(AUTOLOAD DESTROY app cookie finish flash handler on param));
  $r->hide(qw(redirect_to render render_data render_exception render_json));
  $r->hide(qw(render_not_found render_partial render_static render_text));
  $r->hide(qw(rendered req res respond_to send session signed_cookie stash));
  $r->hide(qw(tx ua url_for write write_chunk));

  # Prepare log
  my $mode = $self->mode;
  $self->log->path($home->rel_file("log/$mode.log"))
    if -w $home->rel_file('log');

  # Load default plugins
  $self->plugin($_) for qw(HeaderCondition DefaultHelpers TagHelpers);
  $self->plugin($_) for qw(EPLRenderer EPRenderer RequestTimer PoweredBy);

  # Exception handling
  $self->hook(around_dispatch => \&_exception);

  # Reduced log output outside of development mode
  $self->log->level('info') unless $mode eq 'development';

  # Run mode
  if (my $sub = $self->can("${mode}_mode")) { $self->$sub(@_) }

  # Startup
  $self->startup(@_);

  return $self;
}

sub build_tx {
  my $self = shift;
  my $tx   = Mojo::Transaction::HTTP->new;
  $self->plugins->emit_hook(after_build_tx => $tx, $self);
  return $tx;
}

sub defaults { shift->_dict(defaults => @_) }

sub dispatch {
  my ($self, $c) = @_;

  # Prepare transaction
  my $tx = $c->tx;
  $c->res->code(undef) if $tx->is_websocket;
  $self->sessions->load($c);
  my $plugins = $self->plugins->emit_hook(before_dispatch => $c);

  # Try to find a static file
  $self->static->dispatch($c) unless $tx->res->code;
  $plugins->emit_hook_reverse(after_static_dispatch => $c);

  # Routes
  my $res = $tx->res;
  return if $res->code;
  if (my $code = ($tx->req->error)[1]) { $res->code($code) }
  elsif ($tx->is_websocket) { $res->code(426) }
  $c->render_not_found unless $self->routes->dispatch($c) || $tx->res->code;
}

sub handler {
  my ($self, $tx) = @_;

  # Embedded application
  my $stash = {};
  if (my $sub = $tx->can('stash')) { ($stash, $tx) = ($tx->$sub, $tx->tx) }
  $stash->{'mojo.secret'} //= $self->secret;

  # Build default controller
  my $defaults = $self->defaults;
  @{$stash}{keys %$defaults} = values %$defaults;
  my $c
    = $self->controller_class->new(app => $self, stash => $stash, tx => $tx);
  weaken $c->{$_} for qw(app tx);

  # Dispatcher
  ++$self->{dispatch} and $self->hook(around_dispatch => \&_dispatch)
    unless $self->{dispatch};

  # Process
  unless (eval { $self->plugins->emit_chain(around_dispatch => $c) }) {
    $self->log->fatal("Processing request failed: $@");
    $tx->res->code(500);
    $tx->resume;
  }

  # Delayed
  $self->log->debug('Nothing has been rendered, expecting delayed response.')
    unless $stash->{'mojo.rendered'} || $tx->is_writing;
}

sub helper {
  my ($self, $name, $cb) = @_;
  my $r = $self->renderer;
  $self->log->debug(qq{Helper "$name" already exists, replacing.})
    if exists $r->helpers->{$name};
  $r->add_helper($name => $cb);
}

sub hook { shift->plugins->on(@_) }

sub plugin {
  my $self = shift;
  $self->plugins->register_plugin(shift, $self, @_);
}

sub start { shift->commands->run(@_ ? @_ : @ARGV) }

sub startup { }

sub _dispatch {
  my ($next, $c) = @_;
  $c->app->dispatch($c);
}

sub _exception {
  my ($next, $c) = @_;
  local $SIG{__DIE__}
    = sub { ref $_[0] ? CORE::die($_[0]) : Mojo::Exception->throw(@_) };
  $c->render_exception($@) unless eval { $next->(); 1 };
}

1;

=pod

=encoding utf-8

=head1 文档

Mojolicious - 实时 Web 框架 

=head1 概述

  # 应用
  package MyApp;
  use Mojo::Base 'Mojolicious';

  # 路径选择
  sub startup {
    my $self = shift;
    $self->routes->get('/hello')->to('foo#hello');
  }

  # 控制器
  package MyApp::Foo;
  use Mojo::Base 'Mojolicious::Controller';

  # 动作
  sub hello {
    my $self = shift;
    $self->render(text => 'Hello World!');
  }

=head1 描述

在这有非常不错的文档 L<Mojolicious::Guides>!

=head1 属性

L<Mojolicious> 是从 L<Mojo> 继承了所有的属性，并自己实现了一些新的。

=head2 C<commands>

  my $commands = $app->commands;
  $app         = $app->commands(Mojolicious::Commands->new);

应用的命令行接口，默认是 L<Mojolicious::Commands> 的这个对象.

  # Add another namespace to load commands from
  push @{$app->commands->namespaces}, 'MyApp::Command';

=head2 C<controller_class>

  my $class = $app->controller_class;
  $app      = $app->controller_class('Mojolicious::Controller');

默认的控制器使用的类是 L<Mojolicious::Controller>.

=head2 C<mode>

  my $mode = $app->mode;
  $app     = $app->mode('production');

你当前应用默认的操作模式。默认这个模式会从 C<MOJO_MODE> 的环境变量或 C<development> 中取相应的参数。
也可以加入自定义的到你的应用中，你需要给你的应用中自己的方法名定义成 C<${mode}_mode> 。这个会立即调用 C<startup> 之前调用。

  sub development_mode {
    my $self = shift;
    ...
  }

  sub production_mode {
    my $self = shift;
    ...
  }

在调用 C<startup> 和指定模式方法之前， L<Mojolicious> 会收起当前的模式，重命名日志文件之后会提高日志级别从 C<debug> 到 C<info>。

=head2 C<plugins>

  my $plugins = $app->plugins;
  $app        = $app->plugins(Mojolicious::Plugins->new);

这是插件管理，默认是使用 L<Mojolicious::Plugins> 对象来管理，如果你需要使用插件，你可以看 C<plugin> 相关的方法。

  # Add another namespace to load plugins from
  push @{$app->plugins->namespaces}, 'MyApp::Plugin';

=head2 C<renderer>

  my $renderer = $app->renderer;
  $app         = $app->renderer(Mojolicious::Renderer->new);

你的应用渲染内容使用的是 L<Mojolicious::Renderer> 的对象。
渲染插件主要有二个， L<Mojolicious::Plugin::EPRenderer>  和 L<Mojolicious::Plugin::EPLRenderer> 可以查看相关的模块。

  # Add another "templates" directory
  push @{$app->renderer->paths}, '/home/sri/templates';

  # Add another class with templates in DATA section
  push @{$app->renderer->classes}, 'Mojolicious::Plugin::Fun';

=head2 C<routes>

  my $routes = $app->routes;
  $app       = $app->routes(Mojolicious::Routes->new);

路径选择是使用的 L<Mojolicious::Routes> 的对象，你可以使用这个来定义你的 Url 的指向，在你调用 startup 时你的方法时就会定义。

  sub startup {
    my $self = shift;

    my $r = $self->routes;
    $r->get('/:controller/:action')->to('test#welcome');
  }

=head2 C<secret>

  my $secret = $app->secret;
  $app       = $app->secret('passw0rd');

使用一个秘密的口令签署 cookies 之类。默认在应用中的名字是非常不安全的，所以你需要修改它。如果你在日志中使用默认的不安全的会提示你修改你的密码。

=head2 C<sessions>

  my $sessions = $app->sessions;
  $app         = $app->sessions(Mojolicious::Sessions->new);

基于 session 管理来签署 cookie 。默认是使用 L<Mojolicious::Sessions> 的对象。更加的信息看 L<Mojolicious::Controller/"session">。

=head2 C<static>

  my $static = $app->static;
  $app       = $app->static(Mojolicious::Static->new);

从你的 C<public> 的目录输出静态文件从你的 C<public> 。默认使用 L<Mojolicious::Static> 的对象.

  # Add another "public" directory
  push @{$app->static->paths}, '/home/sri/public';

  # Add another class with static files in DATA section
  push @{$app->static->classes}, 'Mojolicious::Plugin::Fun';

=head2 C<types>

  my $types = $app->types;
  $app      = $app->types(Mojolicious::Types->new);

负责控制传的文件的扩展 MIME 类型.默认是在 L<Mojolicious::Types>  对象中控制。

  $app->types->type(twt => 'text/tweet');

=head1 方法

L<Mojolicious> 是从 L<Mojo> 中继承了全部的方法，并实现了一些.

=head2 C<new>

  my $app = Mojolicious->new;

在你调用 C<${mode}_mode> 和  C<startup> 的时候，会构造一个新的  L<Mojolicious>  应用。这个会自动的设置你的 home 目录和根据你当前模式来设置你的日志和渲染。

=head2 C<build_tx>

  my $tx = $app->build_tx;

Transaction 的创建, 默认是使用的 L<Mojo::Transaction::HTTP> 对象.

=head2 C<defaults>

  my $defaults = $app->defaults;
  my $foo      = $app->defaults('foo');
  $app         = $app->defaults({foo => 'bar'});
  $app         = $app->defaults(foo => 'bar');

对每一次请求，分配定义默认的值存在 L<Mojolicious::Controller/"stash"> 中.

  # Manipulate defaults
  $app->defaults->{foo} = 'bar';
  my $foo = $app->defaults->{foo};
  delete $app->defaults->{foo};

=head2 C<dispatch>

  $app->dispatch(Mojolicious::Controller->new);

这是 Mojolicious 的应用中最重要的要点，每个请求都会通过  L<Mojolicious::Controller> 的对象调度到 C<static> 或 C<routes> 中。

=head2 C<handler>

  $app->handler(Mojo::Transaction::HTTP->new);
  $app->handler(Mojolicious::Controller->new);

设置默认的 controller 和每个请求的处理程序。

=head2 C<helper>

  $app->helper(foo => sub {...});

加入一个新的 helper 方法为你的控制器和应用的对象中可以来调用。当然在 C<ep> 的模板中也可以调用.

  # Helper
  $app->helper(add => sub { $_[1] + $_[2] });

  # Controller/Application
  my $result = $self->add(2, 3);

  # Template
  %= add 2, 3

=head2 C<hook>

  $app->hook(after_dispatch => sub {...});

通过 hooks 点来扩展  L<Mojolicious>。在这注册后可以让你的代码在所有请求中共享使用.

  # Dispatchers will not run if there's already a response code defined
  $app->hook(before_dispatch => sub {
    my $c = shift;
    $c->render(text => 'Skipped dispatchers!')
      if $c->req->url->path->contains('/do_not_dispatch');
  });

当前可以使用的 hooks 点和相关的顺序如下:

=over 2

=item C<after_build_tx>

这个点是工作在 HTTP 的请求还没有被解析，但 transaction 完成时。

  $app->hook(after_build_tx => sub {
    my ($tx, $app) = @_;
    ...
  });

这是一个非常强大的 hook 点，但不应常使用才对。这个地方用来实现一些非常先进的功能如：上传进度条之类，需要注意在 embedded 的应用中不能使用。 (默认参数送的是 transaction and application object)

=item C<before_dispatch>

这个点是工作在静态文件调度和路由选择之前。

  $app->hook(before_dispatch => sub {
    my $c = shift;
    ...
  });

如果你要重写进来的请求和提前做一些处理时非常有用.(默认参数送的是 controller 控制器对象)

=item C<after_static_dispatch>

如果静态文件可以使用并且在路径选择开始之前时，调用这个 hook 点,主要用来做静态调度之后来使用.

  $app->hook(after_static_dispatch => sub {
    my $c = shift;
    ...
  });

主要用来定制调度和静态响应之后做些后处理(post-processing),(默认参数送的是 controller 对象)

=item C<after_dispatch>

响应渲染的内容后调用。注意这个 hook 点会在 C<after_static_dispatch> 之前触发。

  $app->hook(after_dispatch => sub {
    my $c = shift;
    ...
  });

这个主要用来重写响应的输出和其它的处理任务。(默认参数送的是 controller 对象)

=item C<around_dispatch>

在 C<before_dispatch> 的 hook 点之前调用，并环绕整个调度的过程。如果你想控制连接的整个链你可以手动地 forward 到下一个 hook 点。
在异常处理的模块 L<Mojolicious::Controller/"render_exception"> 中，它 hook 了开始的链并在 C<dispatch> 之后还会调用。你的 hook 会放在这个中间的。

  $app->hook(around_dispatch => sub {
    my ($next, $c) = @_;
    ...
    $next->();
    ...
  });

这个 hook 点也非常强大，但你常使用才对。它可以让你定制应用的异常处理之类，你可以给这个工具看成你的工具箱中的大锤一样重要。(传送的参数是下一个 hook 点的回调和 controller 的对象)

=back

=head2 C<plugin>

  $app->plugin('some_thing');
  $app->plugin('some_thing', foo => 23);
  $app->plugin('some_thing', {foo => 23});
  $app->plugin('SomeThing');
  $app->plugin('SomeThing', foo => 23);
  $app->plugin('SomeThing', {foo => 23});
  $app->plugin('MyApp::Plugin::SomeThing');
  $app->plugin('MyApp::Plugin::SomeThing', foo => 23);
  $app->plugin('MyApp::Plugin::SomeThing', {foo => 23});

通过 L<Mojolicious::Plugins/"register_plugin"> 加载插件.

=over 2

=item L<Mojolicious::Plugin::Charset>

改变应用的字符.

=item L<Mojolicious::Plugin::Config>

配置相关

=item L<Mojolicious::Plugin::DefaultHelpers>

常用的 helper 的收集。这个会默认自动加载.

=item L<Mojolicious::Plugin::EPLRenderer>

Renderer for plain embedded Perl templates, loaded automatically.

=item L<Mojolicious::Plugin::EPRenderer>

Renderer for more sophisiticated embedded Perl templates, loaded
automatically.

=item L<Mojolicious::Plugin::HeaderCondition>

Route condition for all kinds of headers, loaded automatically.

=item L<Mojolicious::Plugin::JSONConfig>

JSON  的配置文件.

=item L<Mojolicious::Plugin::Mount>

Mount 所有的 L<Mojolicious> 应用.

=item L<Mojolicious::Plugin::PODRenderer>

渲染 POD 到 HTML 文档浏览器,默认是打开 L<Mojolicious::Guides>.

=item L<Mojolicious::Plugin::PoweredBy>

Add an C<X-Powered-By> header to outgoing responses, loaded automatically.

=item L<Mojolicious::Plugin::RequestTimer>

Log timing information, loaded automatically.

=item L<Mojolicious::Plugin::TagHelpers>

Template specific helper collection, loaded automatically.

=back

=head2 Plugin Xslate

=over 2

=item L<Mojolicious::Plugin::Xslate >

Xslate 的扩展插件

=back

=head2 C<start>

  $app->start;
  $app->start(@ARGV);

Start the command line interface for your application with
L<Mojolicious::Commands/"start">.

  # Always start daemon and ignore @ARGV
  $app->start('daemon', '-l', 'http://*:8080');

=head2 C<startup>

  $app->startup;

This is your main hook into the application, it will be called at application
startup. Meant to be overloaded in a subclass.

  sub startup {
    my $self = shift;
    ...
  }

=head1 HELPERS

In addition to the attributes and methods above you can also call helpers on
L<Mojolicious> objects. This includes all helpers from
L<Mojolicious::Plugin::DefaultHelpers> and L<Mojolicious::Plugin::TagHelpers>.
Note that application helpers are always called with a new default controller
object, so they can't depend on or change controller state, which includes
request, response and stash.

  $app->log->debug($app->dumper({foo => 'bar'}));

=head1 SUPPORT

=head2 Web

L<http://mojolicio.us>

=head2 IRC

C<#mojo> on C<irc.perl.org>

=head2 Mailing-List

L<http://groups.google.com/group/mojolicious>

=head1 DEVELOPMENT

=head2 Repository

L<http://github.com/kraih/mojo>

=head1 BUNDLED FILES

The L<Mojolicious> distribution includes a few files with different licenses
that have been bundled for internal use.

=head2 Mojolicious Artwork

  Copyright (C) 2010-2012, Sebastian Riedel.

Licensed under the CC-SA License, Version 3.0
L<http://creativecommons.org/licenses/by-sa/3.0>.

=head2 jQuery

  Copyright (C) 2011, John Resig.

Licensed under the MIT License, L<http://creativecommons.org/licenses/MIT>.

=head2 prettify.js

  Copyright (C) 2006, Google Inc.

Licensed under the Apache License, Version 2.0
L<http://www.apache.org/licenses/LICENSE-2.0>.

=head1 CODE NAMES

Every major release of L<Mojolicious> has a code name, these are the ones that
have been used in the past.

3.0, C<Rainbow> (u1F308)

2.0, C<Leaf Fluttering In Wind> (u1F343)

1.4, C<Smiling Face With Sunglasses> (u1F60E)

1.3, C<Tropical Drink> (u1F379)

1.1, C<Smiling Cat Face With Heart-Shaped Eyes> (u1F63B)

1.0, C<Snowflake> (u2744)

0.999930, C<Hot Beverage> (u2615)

0.999927, C<Comet> (u2604)

0.999920, C<Snowman> (u2603)

=head1 PROJECT FOUNDER

Sebastian Riedel, C<sri@cpan.org>

=head1 CORE DEVELOPERS

Current members of the core team in alphabetical order:

=over 4

Abhijit Menon-Sen, C<ams@cpan.org>

Glen Hinkle, C<tempire@cpan.org>

Marcus Ramberg, C<mramberg@cpan.org>

=back

=head1 CREDITS

In alphabetical order:

=over 2

Adam Kennedy

Adriano Ferreira

Al Newkirk

Alex Salimon

Alexey Likhatskiy

Anatoly Sharifulin

Andre Vieth

Andreas Jaekel

Andreas Koenig

Andrew Fresh

Andrey Khozov

Andy Grundman

Aristotle Pagaltzis

Ashley Dev

Ask Bjoern Hansen

Audrey Tang

Ben van Staveren

Benjamin Erhart

Bernhard Graf

Breno G. de Oliveira

Brian Duggan

Burak Gursoy

Ch Lamprecht

Charlie Brady

Chas. J. Owens IV

Christian Hansen

chromatic

Curt Tilmes

Daniel Kimsey

Danijel Tasov

Danny Thomas

David Davis

David Webb

Diego Kuperman

Dmitriy Shalashov

Dmitry Konstantinov

Dominique Dumont

Douglas Christopher Wilson

Eugene Toropov

Gisle Aas

Graham Barr

Henry Tang

Hideki Yamamura

Ilya Chesnokov

James Duncan

Jan Jona Javorsek

Jaroslav Muhin

Jesse Vincent

Joel Berger

Johannes Plunien

John Kingsley

Jonathan Yu

Kazuhiro Shibuya

Kevin Old

Kitamura Akatsuki

Lars Balker Rasmussen

Leon Brocard

Magnus Holm

Maik Fischer

Mark Stosberg

Marty Tennison

Matthew Lineen

Maksym Komar

Maxim Vuets

Michael Harris

Mike Magowan

Mirko Westermeier

Mons Anderson

Moritz Lenz

Neil Watkiss

Nic Sandfield

Nils Diewald

Oleg Zhelo

Pascal Gaudette

Paul Evans

Paul Tomlin

Pedro Melo

Peter Edwards

Pierre-Yves Ritschard

Quentin Carbonneaux

Rafal Pocztarski

Randal Schwartz

Robert Hicks

Robin Lee

Roland Lammel

Ryan Jendoubi

Sascha Kiefer

Scott Wiersdorf

Sergey Zasenko

Simon Bertrang

Simone Tampieri

Shu Cho

Skye Shaw

Stanis Trendelenburg

Stephane Este-Gracias

Tatsuhiko Miyagawa

Terrence Brannon

The Perl Foundation

Tomas Znamenacek

Ulrich Habel

Ulrich Kautz

Uwe Voelker

Viacheslav Tykhanovskyi

Victor Engmark

Viliam Pucik

Wes Cravens

Yaroslav Korshak

Yuki Kimoto

Zak B. Elep

=back

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2008-2012, Sebastian Riedel.

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=cut
