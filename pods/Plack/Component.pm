package Plack::Component;
use strict;
use warnings;
use Carp ();
use Plack::Util;
use overload '&{}' => \&to_app_auto, fallback => 1;

sub new {
    my $proto = shift;
    my $class = ref $proto || $proto;

    my $self;
    if (@_ == 1 && ref $_[0] eq 'HASH') {
        $self = bless {%{$_[0]}}, $class;
    } else {
        $self = bless {@_}, $class;
    }

    $self;
}

sub to_app_auto {
    my $self = shift;
    if (($ENV{PLACK_ENV} || '') eq 'development') {
        my $class = ref($self);
        warn "WARNING: Automatically converting $class instance to a PSGI code reference. " .
          "If you see this warning for each request, you probably need to explicitly call " .
          "to_app() i.e. $class->new(...)->to_app in your PSGI file.\n";
    }
    $self->to_app(@_);
}

# NOTE:
# this is for back-compat only,
# future modules should use
# Plack::Util::Accessor directly
# or their own favorite accessor
# generator.
# - SL
sub mk_accessors {
    my $self = shift;
    Plack::Util::Accessor::mk_accessors( ref( $self ) || $self, @_ )
}

sub prepare_app { return }

sub to_app {
    my $self = shift;
    $self->prepare_app;
    return sub { $self->call(@_) };
}


sub response_cb {
    my($self, $res, $cb) = @_;
    Plack::Util::response_cb($res, $cb);
}

1;

__END__

=head1 NAME

Plack::Component - Base class for PSGI endpoints

=head1 SYNOPSIS

  package Plack::App::Foo;
  use parent qw( Plack::Component );

  sub call {
      my($self, $env) = @_;
      # Do something with $env

      my $res = ...; # create a response ...

      # return the response
      return $res;
  }

=head1 DESCRIPTION

Plack::Component is the base class shared between L<Plack::Middleware>
and C<Plack::App::*> modules. If you are writing middleware, you should
inherit from L<Plack::Middleware>, but if you are writing a
Plack::App::* you should inherit from this directly.

=head1 REQUIRED METHOD

=over 4

=item call ($env)

You are expected to implement a C<call> method in your component. This
is where all the work gets done. It receives the PSGI C<$env> hash-ref
as an argument and is expected to return a proper PSGI response value.

=back

=head1 METHODS

=over 4

=item new (%opts | \%opts)

The constructor accepts either a hash or a hashref and uses that to
create the instance. It will call no other methods and simply return
the instance that is created.

=item prepare_app

这个方法被 C<to_app> 调用, 这是一个 hook 点, 用于在打包你的 PSGI C<$app> 之前准备你的一些组件.

=item to_app

这个方法在 Plack 的架构中多个地方都使用了, 用于转换你的组件到 PSGI C<$app>.
你没有必要重写这个方法; 推荐你使用 C<prepare_app> 和 C<call> 替换.

=item response_cb

这是对 L<Plack::Util> 中的 C<response_cb> 的封装. 你可以看 L<Plack::Middleware/RESPONSE CALLBACK>.

=back

=head1 OBJECT LIFECYCLE

(Plack::App::* or Plack::Middleware::* 导出的类的对象是在 PSGI 应用编译
阶段由 C<new>, C<prepare_app> 和 C<to_app> 产生, 这个创建的对象是一个持久的直到 web 服务器的
生命周期, 除非是使用的非持续的环境象 CGI. 这个 C<call> 的是在请求到来的时候, 由相同的对象调用.

你可以检查 你的运行是否是 persistent 环境, 通过检查在 C<$env> 中的  C<psgi.run_once> 这个, 
如果是 (non-persistent) 会得到 true 或者 false (persistent). 但你是写自己的中间件时为了保持在持续环境
你应避免保存每个请求的数据如果 C<$env> 到你的对象.

=head1 BACKWARDS COMPATIBILITY

The L<Plack::Middleware> module used to inherit from L<Class::Accessor::Fast>,
which has been removed in favor of the L<Plack::Util::Accessor> module. When
developing new components it is recommended to use L<Plack::Util::Accessor>
like so:

  use Plack::Util::Accessor qw( foo bar baz );

However, in order to keep backwards compatibility this module provides a
C<mk_accessors> method similar to L<Class::Accessor::Fast>. New code should
not use this and use L<Plack::Util::Accessor> instead.

=head1 SEE ALSO

L<Plack> L<Plack::Builder> L<Plack::Middleware>

=cut
