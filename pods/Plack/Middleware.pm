package Plack::Middleware;
use strict;
use warnings;
use Carp ();
use parent qw(Plack::Component);
use Plack::Util;
use Plack::Util::Accessor qw( app );

sub wrap {
    my($self, $app, @args) = @_;
    if (ref $self) {
        $self->{app} = $app;
    } else {
        $self = $self->new({ app => $app, @args });
    }
    return $self->to_app;
}

1;

__END__
=encoding utf-8

=head1 NAME

Plack::Middleware - Base class for easy-to-use PSGI middleware

=head1 SYNOPSIS

  package Plack::Middleware::Foo;
  use parent qw( Plack::Middleware );

  sub call {
      my($self, $env) = @_;
      # 对 $env 做相关操作

      # $self->app 是源始的 app
      my $res = $self->app->($env);

      # 对 $res 的响应做一些操作
      return $res;
  }

  # then in app.psgi
  use Plack::Builder;

  my $app = sub { ... } # as usual

  builder {
      enable "Plack::Middleware::Foo";
      enable "Plack::Middleware::Bar", %options;
      $app;
  };

=head1 DESCRIPTION

Plack::Middleware 是用于写 PSGI 的中间件的基础类的工具. 你需要在
自己的中间件中从 Plack::Middleware 继承然后实现回调 C<call> 的方
法 (或者 C<to_app> 的方法来用于返回 PSGI 的代码引用) 才能正常工作.
你可以直接 C<< $self->app >> 来调用原始的应用.

你的中间件的对象是创建于 PSGI 应用编译的时候, 它是持续 persistent 到 web 服务器的
生命周期.(除非是象 CGI 这种非持续 non-persistent 环境变量的应用), 所以你应设置和缓存
预请求 per-request 的数据象 C<$env> 在你的应用的对象当中. See also L<Plack::Component/"OBJECT LIFECYCLE">.

可以查看 L<Plack::Builder> 来看看怎么样在你的 I<.psgi> 的应用中使用 DSL 风格启用中间件. 
如果你不喜欢 DSL 风格, 你需要使用 C<wrap> 的方法在你的中间件中来封装你的应用.

  use Plack::Middleware::Foo;

  my $app = sub { ... };
  $app = Plack::Middleware::Foo->wrap($app, %options);
  $app = Plack::Middleware::Bar->wrap($app, %options);

=head1 回调响应 RESPONSE CALLBACK

一个典型的中间件是象下面这样:

  package Plack::Middleware::Something;
  use parent qw(Plack::Middleware);

  sub call {
      my($self, $env) = @_;
      #  预处理 pre-processing $env
      my $res = $self->app->($env);
      #  后处理 post-processing $res
      return $res;
  }

对于响应的后处理更加的复杂, 因为它可能返回的是 3 个元素的数组引用, 或者是延迟
响应 (streaming) 接口实现的代码块的引用.

对这两种类型, 在每个中间件响应中都去处理是是没有意义的, 所以你推荐使用 C<response_cb> 包装
的 L<Plack::Util> 函数来实现后处理的中间件.

  sub call {
      my($self, $env) = @_;
      # pre-processing $env
      my $res = $app->($env);

      return Plack::Util::response_cb($res, sub {
          my $res = shift;
          # do something with $res;
      });
  }

这个回调的功能取得响应的数组引用, 你可以更新引用的数组来实现后处理. 在一个标准的实例中, 
这个数组会有三个元素 (就象 PSGI spec 中描述的一样), 但有时可能只有二个元素, 然后需要通过 C<$writer> 来写其它数据.

  package Plack::Middleware::Always500;
  use parent qw(Plack::Middleware);
  use Plack::Util;

  sub call {
      my($self, $env) = @_;
      my $res  = $self->app->($env);
      return Plack::Util::response_cb($res, sub {
          my $res = shift;
          $res->[0] = 500;
          return;
      });
  }

在这个例子中, 回调取得 C<$res> 然后更新第一个元素 (状态码) 为 500. 使用 C<response_cb> 可以确保在延迟响应中也能工作.

你没有必要 (也不推荐) 来返回一个新的数组引用 - 这是一个容易出的错误, 他们会被忽略掉.
建议你明确的返回, 除非你把内容送进 filter 筛选器的回调. 如下:

同样, 你需要保持你的 C<$res> 是引用. 当你改变你的响应的时候.

  Plack::Util::response_cb($res, sub {
      my $res = shift;
      $res = [ $new_status, $new_headers, $new_body ]; # THIS DOES NOT WORK
      return;
  });

这是不能工作的, 这会分配一个新的匿名数组到 C<$res>. 但并不会更新原始的 PSGI 的响应值. 你需要使用下面这种做法:

  Plack::Util::response_cb($res, sub {
      my $res = shift;
      @$res = ($new_status, $new_headers, $new_body); # THIS WORKS
      return;
  });

在响应的数组引用中第三个元素是 body, 这可以是一个数组引用, 或者是 L<IO::Handle> 的对象. 
如果是 C<psgi.streaming> 是生效的会使用 C<$writer> 的对象, 在这种情况下,
第三个元素会不存在 (C<@$res == 2>).  处理这种变异有些痛苦, 但我们可以使用 C<response_cb> 来返回内容过滤用的代码引用. 

  # replace all "Foo" in content body with "Bar"
  Plack::Util::response_cb($res, sub {
      my $res = shift;
      return sub {
          my $chunk = shift;
          return unless defined $chunk;
          $chunk =~ s/Foo/Bar/g;
          return $chunk;
      }
  });

这个回调会取得一个参数  C<$chunk> , 这时这个回调会更新 chunk. 如果给的 C<$chunk> 是空的, 这
表示 stream 结束了, 所以你的 callback 也需要返回 undef.

=head1 SEE ALSO

L<Plack> L<Plack::Builder> L<Plack::Component>

=cut
