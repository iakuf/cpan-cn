package Mojolicious::Plugin::DefaultHelpers;
use Mojo::Base 'Mojolicious::Plugin';

use Data::Dumper ();
use Mojo::ByteStream;

sub register {
  my ($self, $app) = @_;

  # Controller alias helpers
  for my $name (qw(app flash param stash session url_for)) {
    $app->helper($name => sub { shift->$name(@_) });
  }

  # Stash key shortcuts
  for my $name (qw(extends layout title)) {
    $app->helper(
      $name => sub {
        my $self  = shift;
        my $stash = $self->stash;
        $stash->{$name} = shift if @_;
        $self->stash(@_) if @_;
        return $stash->{$name};
      }
    );
  }

  # Add "config" helper
  $app->helper(config => sub { shift->app->config(@_) });

  # Add "content" helper
  $app->helper(content => \&_content);

  # Add "content_for" helper
  $app->helper(content_for => \&_content_for);

  # Add "current_route" helper
  $app->helper(current_route => \&_current_route);

  # Add "dumper" helper
  $app->helper(dumper => \&_dumper);

  # Add "include" helper
  $app->helper(include => \&_include);

  # Add "memorize" helper
  my %mem;
  $app->helper(
    memorize => sub {
      my $self = shift;
      return '' unless ref(my $cb = pop) eq 'CODE';
      my ($name, $args)
        = ref $_[0] eq 'HASH' ? (undef, shift) : (shift, shift || {});

      # Default name
      $name ||= join '', map { $_ || '' } (caller(1))[0 .. 3];

      # Expire old results
      my $expires = $args->{expires} || 0;
      delete $mem{$name}
        if exists $mem{$name} && $expires > 0 && $mem{$name}{expires} < time;

      # Memorized result
      return $mem{$name}{content} if exists $mem{$name};

      # Memorize new result
      $mem{$name}{expires} = $expires;
      return $mem{$name}{content} = $cb->();
    }
  );

  # DEPRECATED in Rainbow!
  $app->helper(
    render_content => sub {
      warn "Mojolicious::Controller->render_content is DEPRECATED!\n";
      shift->content(@_);
    }
  );

  # Add "url_with" helper
  $app->helper(url_with => \&_url_with);
}

sub _content {
  my ($self, $name, $content) = @_;
  $name ||= 'content';

  # Set (first come)
  my $c = $self->stash->{'mojo.content'} ||= {};
  $c->{$name} ||= ref $content eq 'CODE' ? $content->() : $content
    if defined $content;

  # Get
  return Mojo::ByteStream->new($c->{$name} // '');
}

sub _content_for {
  my ($self, $name, $content) = @_;
  return _content($self, $name) unless defined $content;
  my $c = $self->stash->{'mojo.content'} ||= {};
  return $c->{$name} .= ref $content eq 'CODE' ? $content->() : $content;
}

sub _current_route {
  return '' unless my $endpoint = shift->match->endpoint;
  return $endpoint->name unless @_;
  return $endpoint->name eq shift;
}

sub _dumper { shift; Data::Dumper->new([@_])->Indent(1)->Terse(1)->Dump }

sub _include {
  my $self     = shift;
  my $template = @_ % 2 ? shift : undef;
  my $args     = {@_};
  $args->{template} = $template if defined $template;

  # "layout" and "extends" can't be localized
  my $layout  = delete $args->{layout};
  my $extends = delete $args->{extends};

  # Localize arguments
  my @keys = keys %$args;
  local @{$self->stash}{@keys} = @{$args}{@keys};

  return $self->render_partial(layout => $layout, extend => $extends);
}

sub _url_with {
  my $self = shift;
  return $self->url_for(@_)->query($self->req->url->query->clone);
}

1;

=pod

=encoding utf-8

=head1 文档

Mojolicious::Plugin::DefaultHelpers - 默认的 helpers 插件

=head1 概述

  # Mojolicious
  $self->plugin('DefaultHelpers');

  # Mojolicious::Lite
  plugin 'DefaultHelpers';

=head1 描述

L<Mojolicious::Plugin::DefaultHelpers> 中收集了所有的 L<Mojolicious> 渲染模板用的 Helpers.扶凯： 其实这个就是传给模板技术使用的一些函数，可以让你在模板中调用。

这是一个核心插件，这意味着它总是开户的。这个中的代码是非常好的例子，学习来创建新插件的话，可以考虑直接 fork 它.

=head1 HELPERS

L<Mojolicious::Plugin::DefaultHelpers> 实现了下面这些 helpers. 扶凯: 注意如果使用其它的模板插件要调用这些功能，比如 Xslate 的模板插件，如果要使用这些 helpers 的话，只需要使用 $c.method 这种方式来调用就行了。

=head2 C<app>

  %= app->secret

这是 L<Mojolicious::Controller/"app"> 的别名.

=head2 C<config>

  %= config 'something'

这是 L<Mojo/"config"> 的别名。

=head2 C<content>

  %= content foo => begin
    test
  % end
  %= content bar => 'Hello World!'
  %= content 'foo'
  %= content 'bar'
  %= content

存储部分要显示的内容到指定名字的缓冲区和并可以检索它.

=head2 C<content_for>

  % content_for foo => begin
    test
  % end
  %= content_for 'foo'

追加分要显示的内容到指定名字的缓冲区和并可以检索它

  % content_for message => begin
    Hello
  % end
  % content_for message => begin
    world!
  % end
  %= content_for 'message'

=head2 C<current_route>

  % if (current_route 'login') {
    Welcome to Mojolicious!
  % }
  %= current_route

检查 current_route 的这个名字.

=head2 C<dumper>

  %= dumper {some => 'data'}

使用 L<Data::Dumper> 这个模块 Dump 出数组成 Perl 的数组结构。

=head2 C<extends>

  % extends 'blue';
  % extends 'blue', title => 'Blue!';

扩展模板。所有额外的值会合并到 C<stash>.

=head2 C<flash>

  %= flash 'foo'

这个是 L<Mojolicious::Controller/"flash"> 的别名.

=head2 C<include>

  %= include 'menubar'
  %= include 'menubar', format => 'txt'

包括进来部分的模板，所有的参数需要加在后面，只可用在局部模板上。

=head2 C<layout>

  % layout 'green';
  % layout 'green', title => 'Green!';

显示 layout 的模板，附加上的值会合并到 C<stash>.

=head2 C<memorize>

  %= memorize begin
    %= time
  % end
  %= memorize {expires => time + 1} => begin
    %= time
  % end
  %= memorize foo => begin
    %= time
  % end
  %= memorize foo => {expires => time + 1} => begin
    %= time
  % end

记住块中的的结果在内存中，预防将来执行时在次用到.

=head2 C<param>

  %= param 'foo'

L<Mojolicious::Controller/"param"> 的别名.

=head2 C<session>

  %= session 'foo'

L<Mojolicious::Controller/"session"> 的别名.

=head2 C<stash>

  %= stash 'foo'
  % stash foo => 'bar';

L<Mojolicious::Controller/"stash"> 的别名.

  %= stash 'name' // 'Somebody'

=head2 C<title>

  % title 'Welcome!';
  % title 'Welcome!', foo => 'bar';
  %= title

网页的 title. 附加的值会合并到 C<stash>.

=head2 C<url_for>

  %= url_for 'named', controller => 'bar', action => 'baz'

L<Mojolicious::Controller/"url_for"> 的别名.

=head2 C<url_with>

  %= url_with 'named', controller => 'bar', action => 'baz'

这个有点象  C<url_for>, 但是继承当前网页的查询参数。

  %= url_with->query([page => 2])

=head1 METHODS

L<Mojolicious::Plugin::DefaultHelpers> 继承全部的 L<Mojolicious::Plugin> 的方法，并自己实现了一些.

=head2 C<register>

  $plugin->register(Mojolicious->new);

注册一个 helpers 到 L<Mojolicious>  的应用.

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
