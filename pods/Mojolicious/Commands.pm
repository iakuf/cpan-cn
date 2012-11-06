package Mojolicious::Commands;
use Mojo::Base 'Mojolicious::Command';

use Getopt::Long
  qw(GetOptions :config no_auto_abbrev no_ignore_case pass_through);
use Mojo::Server;

has hint => <<"EOF";

These options are available for all commands:
    -h, --help          Get more information on a specific command.
        --home <path>   Path to your applications home directory, defaults to
                        the value of MOJO_HOME or auto detection.
    -m, --mode <name>   Run mode of your application, defaults to the value
                        of MOJO_MODE or "development".

See '$0 help COMMAND' for more information on a specific command.
EOF
has message => <<"EOF";
usage: $0 COMMAND [OPTIONS]

Tip: CGI and PSGI environments can be automatically detected very often and
     work without commands.

These commands are currently available:
EOF
has namespaces => sub { ['Mojolicious::Command'] };

sub detect {
  my ($self, $guess) = @_;

  # PSGI (Plack only for now)
  return 'psgi' if defined $ENV{PLACK_ENV};

  # CGI
  return 'cgi' if defined $ENV{PATH_INFO} || defined $ENV{GATEWAY_INTERFACE};

  # Nothing
  return $guess;
}

# Command line options for MOJO_HELP, MOJO_HOME and MOJO_MODE
BEGIN {
  GetOptions(
    'h|help'   => sub { $ENV{MOJO_HELP} = 1 },
    'home=s'   => sub { $ENV{MOJO_HOME} = $_[1] },
    'm|mode=s' => sub { $ENV{MOJO_MODE} = $_[1] }
  ) unless __PACKAGE__->detect;
}

sub run {
  my ($self, $name, @args) = @_;

  # Application loader
  return $self->app if defined $ENV{MOJO_APP_LOADER};

  # Try to detect environment
  $name = $self->detect($name) unless $ENV{MOJO_NO_DETECT};

  # Run command
  if ($name && $name =~ /^\w+$/ && ($name ne 'help' || $args[0])) {

    # Help
    $name = shift @args if my $help = $name eq 'help';
    $help = $ENV{MOJO_HELP} = $ENV{MOJO_HELP} ? 1 : $help;

    # Try all namespaces
    my $module;
    $module = _command("${_}::$name", 1) and last for @{$self->namespaces};

    # Unknown command
    die qq{Unknown command "$name", maybe you need to install it?\n}
      unless $module;

    # Run
    my $command = $module->new(app => $self->app);
    return $help ? $command->help(@args) : $command->run(@args);
  }

  # Test
  return 1 if $ENV{HARNESS_ACTIVE};

  # Try all namespaces
  my (@commands, %seen);
  my $loader = Mojo::Loader->new;
  for my $namespace (@{$self->namespaces}) {
    for my $module (@{$loader->search($namespace)}) {
      next unless my $command = _command($module);
      $command =~ s/^${namespace}:://;
      push @commands, [$command => $module] unless $seen{$command}++;
    }
  }

  # Make list
  my @list;
  my $max = 0;
  for my $command (@commands) {
    my $len = length $command->[0];
    $max = $len if $len > $max;
    push @list, [$command->[0], $command->[1]->new->description];
  }

  # Print list
  print $self->message;
  for my $command (@list) {
    my ($name, $description) = @$command;
    print "  $name" . (' ' x ($max - length $name)) . "   $description";
  }
  return print $self->hint;
}

sub start {
  my $self = shift;
  return $self->start_app($ENV{MOJO_APP} => @_) if $ENV{MOJO_APP};
  return $self->new->app->start(@_);
}

sub start_app {
  my $self = shift;
  return Mojo::Server->new->build_app(shift)->start(@_);
}

sub _command {
  my ($module, $fatal) = @_;
  return $module->isa('Mojolicious::Command') ? $module : undef
    unless my $e = Mojo::Loader->new->load($module);
  $fatal && ref $e ? die $e : return undef;
}

1;

=pod

=encoding utf-8

=head1 文档名

Mojolicious::Commands - 命令行接口 

=head1 概要

  use Mojolicious::Commands;

  my $commands = Mojolicious::Commands->new;
  push @{$commands->namespaces}, 'MyApp::Command';
  $commands->run('daemon');

=head1  描述

L<Mojolicious::Commands>  是 L<Mojolicious> 框架的命令行接口. 这个会自动的使用 C<Mojolicious::Command> 名字空间的调用。 

=head1 命令

这些是默认可以使用的命令.

=head2 C<help>

  $ mojo
  $ mojo help
  $ ./myapp.pl help

列出所有的命令使用短的描述。

  $ mojo help <command>
  $ ./myapp.pl help <command>

列出命令的可用选项的简短说明。

=head2 C<cgi>

  $ ./myapp.pl cgi

列出可用的 CGI 的后端，通常自动的发现.

=head2 C<cpanify>

  $ mojo cpanify -u sri -p secr3t Mojolicious-Plugin-Fun-0.1.tar.gz

更新文件到 CPAN.

=head2 C<daemon>

  $ ./myapp.pl daemon

开始应用使用单进程的 HTTP 服务器做为后端.

=head2 C<eval>

  $ ./myapp.pl eval 'say app->home'

钟对应用运行指定代码。

=head2 C<generate>

  $ mojo generate
  $ mojo generate help
  $ ./myapp.pl generate help

列出 generator 命令的简短描述.

  $ mojo generate help <generator>
  $ ./myapp.pl generate help <generator>

列出 generator 命令可用的选项.

=head2 C<generate app>

  $ mojo generate app <AppName>

生成一个全功能的  L<Mojolicious> 应用相关的目录结构。

=head2 C<generate lite_app>

  $ mojo generate lite_app

创建一个全功能的 L<Mojolicious::Lite>  应用.

=head2 C<generate makefile>

  $ mojo generate makefile
  $ ./myapp.pl generate makefile

为应用创建 C<Makefile.PL> 文件

=head2 C<generate plugin>

  $ mojo generate plugin <PluginName>

生成 L<Mojolicious> 全功能的插件的目录架构。

=head2 C<get>

  $ mojo get http://mojolicio.us
  $ ./myapp.pl get /foo

对本地 or 远程的主机执行请求

=head2 C<inflate>

  $ ./myapp.pl inflate

给你应用中的  C<DATA> 部分的内容中的模板和静态文件生成到相应的真实目录。

=head2 C<psgi>

  $ ./myapp.pl psgi

使用 PSGI 来启动你的应用。通常会自动发现。

=head2 C<routes>

  $ ./myapp.pl routes

列出应用所有的 routes.

=head2 C<test>

  $ mojo test
  $ ./myapp.pl test
  $ ./myapp.pl test t/fun.t

从  C<t> 目录来运行应用的测试.

=head2 C<version>

  $ mojo version
  $ ./myapp.pl version

显示你安装的核心和模块的版本.这个在 debug 的时候常用.

=head1 属性

L<Mojolicious::Commands>  从  L<Mojolicious::Command> 中继承所有的属性，并自己实现了以下新的。

=head2 C<hint>

  my $hint  = $commands->hint;
  $commands = $commands->hint('Foo!');

列出可用的命令后，显示一个短提示。

=head2 C<message>

  my $msg   = $commands->message;
  $commands = $commands->message('Hello World!');

显示简短的用法，然后再列出可用的命令。

=head2 C<namespaces>

  my $namespaces = $commands->namespaces;
  $commands      = $commands->namespaces(['MyApp::Command']);

命名空间的加载命令，默认是使用的 C<Mojolicious::Command>.

  # Add another namespace to load commands from
  push @{$commands->namespaces}, 'MyApp::Command';

=head1 方法

L<Mojolicious::Commands> 是从  L<Mojolicious::Command> 继承了全部的方法，并实现了下列新的.

=head2 C<detect>

  my $env = $commands->detect;
  my $env = $commands->detect($guess);

尝试检测环境。

=head2 C<run>

  $commands->run;
  $commands->run(@ARGV);

加载和运行的命令，可以在这通过 C<MOJO_NO_DETECT>  来禁用自动部署环境。

=head2 C<start>

  Mojolicious::Commands->start;
  Mojolicious::Commands->start(@ARGV);

使用 C<MOJO_APP> 的环境变量或者 L<Mojo::HelloWorld> 来使用命令行接口来启动应用。

  # Always start daemon and ignore @ARGV
  Mojolicious::Commands->start('daemon', '-l', 'http://*:8080');

=head2 C<start_app>

  Mojolicious::Commands->start_app('MyApp');
  Mojolicious::Commands->start_app(MyApp => @ARGV);

加载应用和使用命令行接口来启动它。

  # Always start daemon for application and ignore @ARGV
  Mojolicious::Commands->start_app('MyApp', 'daemon', '-l', 'http://*:8080');

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
