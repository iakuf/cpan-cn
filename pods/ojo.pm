package ojo;
use Mojo::Base -strict;

use Mojo::ByteStream 'b';
use Mojo::Collection 'c';
use Mojo::DOM;
use Mojo::JSON;
use Mojo::UserAgent;

# Silent oneliners
$ENV{MOJO_LOG_LEVEL} ||= 'fatal';

# User agent
my $UA = Mojo::UserAgent->new;

sub import {

  # Prepare exports
  my $caller = caller;
  no strict 'refs';
  no warnings 'redefine';

  # Mojolicious::Lite
  eval "package $caller; use Mojolicious::Lite;";

  # Allow redirects
  $UA->max_redirects(10) unless defined $ENV{MOJO_MAX_REDIRECTS};

  # Detect proxy
  $UA->detect_proxy unless defined $ENV{MOJO_PROXY};

  # Application
  $UA->app(*{"${caller}::app"}->());

  # Functions
  *{"${caller}::a"} = sub { *{"${caller}::any"}->(@_) and return $UA->app };
  *{"${caller}::b"} = \&b;
  *{"${caller}::c"} = \&c;
  *{"${caller}::d"} = sub { _request($UA->build_tx(DELETE => @_)) };
  *{"${caller}::f"} = sub { _request($UA->build_form_tx(@_)) };
  *{"${caller}::g"} = sub { _request($UA->build_tx(GET => @_)) };
  *{"${caller}::h"} = sub { _request($UA->build_tx(HEAD => @_)) };
  *{"${caller}::j"} = sub {
    my $d = shift;
    my $j = Mojo::JSON->new;
    return $j->encode($d) if ref $d eq 'ARRAY' || ref $d eq 'HASH';
    return $j->decode($d);
  };
  *{"${caller}::n"} = sub { _request($UA->build_json_tx(@_)) };
  *{"${caller}::o"} = sub { _request($UA->build_tx(OPTIONS => @_)) };
  *{"${caller}::p"} = sub { _request($UA->build_tx(POST => @_)) };
  *{"${caller}::r"} = sub { $UA->app->dumper(@_) };
  *{"${caller}::t"} = sub { _request($UA->build_tx(PATCH => @_)) };
  *{"${caller}::u"} = sub { _request($UA->build_tx(PUT => @_)) };
  *{"${caller}::x"} = sub { Mojo::DOM->new(@_) };
}

sub _request {
  my $tx = $UA->start(@_);
  my ($err, $code) = $tx->error;
  warn qq/Problem loading URL "@{[$tx->req->url->to_abs]}". ($err)\n/
    if $err && !$code;
  return $tx->res;
}

1;

=pod

=encoding utf-8

=head1 文档

ojo - 单个字母的 Mojo 的功能 

=head1 概要

  $ perl -Mojo -E 'say g("mojolicio.us")->dom->at("title")->text'

=head1 描述

这是一个非常有意思的东西就是 Perl 的单行功能合集。 默认的情况下，可以重定向 10 次，你可以修改  C<MOJO_MAX_REDIRECTS> 来改变它的行为.

  $ MOJO_MAX_REDIRECTS=0 perl -Mojo -E 'say g("mojolicio.us")->code'

默认也是打开了代理检查的功能，如果你想禁用这个功能，就使用 C<MOJO_PROXY> 的环境变量来修改它.

  $ MOJO_PROXY=0 perl -Mojo -E 'say g("mojolicio.us")->body'

=head1 函数

L<ojo> 实现了下列的函数

=head2 C<a>

  my $app = a('/hello' => sub { shift->render(json => {hello => 'world'}) });

使用 L<Mojolicious::Lite/"any">  中的 route  功能来创建一个 L<Mojolicious::Lite> 对象，你可以看  L<Mojolicious::Lite> 的教程中参数的详细信息.

  $ perl -Mojo -E 'a("/hello" => {text => "Hello Mojo!"})->start' daemon

=head2 C<b>

  my $stream = b('lalala');

打开 L<Mojo::ByteStream> 对象字符.

  $ perl -Mojo -E 'b(g("mojolicio.us")->body)->html_unescape->say'

=head2 C<c>

  my $collection = c(1, 2, 3);

打开列出  L<Mojo::Collection>  对象的功能.

=head2 C<d>

  my $res = d('mojolicio.us');
  my $res = d('http://mojolicio.us' => {DNT => 1} => 'Hi!');

使用 L<Mojo::UserAgent/"delete"> 中的 C<DELETE> 请求并返回 L<Mojo::Message::Response> 对象.

=head2 C<f>

  my $res = f('http://kraih.com' => {a => 'b'});
  my $res = f('kraih.com' => 'UTF-8' => {a => 'b'} => {DNT => 1});

Perform C<POST> request with L<Mojo::UserAgent/"post_form"> and return
resulting L<Mojo::Message::Response> object.

=head2 C<g>

  my $res = g('mojolicio.us');
  my $res = g('http://mojolicio.us' => {DNT => 1} => 'Hi!');

Perform C<GET> request with L<Mojo::UserAgent/"get"> and return resulting
L<Mojo::Message::Response> object.

  $ perl -Mojo -E 'say g("mojolicio.us")->dom("h1, h2, h3")->pluck("text")'

=head2 C<h>

  my $res = h('mojolicio.us');
  my $res = h('http://mojolicio.us' => {DNT => 1} => 'Hi!');

Perform C<HEAD> request with L<Mojo::UserAgent/"head"> and return resulting
L<Mojo::Message::Response> object.

=head2 C<j>

  my $bytes = j({foo => 'bar'});
  my $array = j($bytes);
  my $hash  = j($bytes);

Encode Perl data structure or decode JSON with L<Mojo::JSON>.

  $ perl -Mojo -E 'b(j({hello => "world!"}))->spurt("hello.json")'

=head2 C<n>

  my $res = n('http://kraih.com' => {a => 'b'});
  my $res = n('kraih.com' => {a => 'b'} => {DNT => 1});

Perform C<POST> request with L<Mojo::UserAgent/"post_json"> and return
resulting L<Mojo::Message::Response> object.

=head2 C<o>

  my $res = o('mojolicio.us');
  my $res = o('http://mojolicio.us' => {DNT => 1} => 'Hi!');

Perform C<OPTIONS> request with L<Mojo::UserAgent/"options"> and return
resulting L<Mojo::Message::Response> object.

=head2 C<p>

  my $res = p('mojolicio.us');
  my $res = p('http://mojolicio.us' => {DNT => 1} => 'Hi!');

Perform C<POST> request with L<Mojo::UserAgent/"post"> and return resulting
L<Mojo::Message::Response> object.

=head2 C<r>

  my $perl = r({data => 'structure'});

给  Perl 的数据结构使用 L<Data::Dumper> 来 Dump 出来。

  perl -Mojo -E 'say r(g("mojolicio.us")->headers->to_hash)'

=head2 C<t>

  my $res = t('mojolicio.us');
  my $res = t('http://mojolicio.us' => {DNT => 1} => 'Hi!');

使用 L<Mojo::UserAgent/"patch"> 中发出 C<PATCH> 的请求并返回 L<Mojo::Message::Response> 的对象.

=head2 C<u>

  my $res = u('mojolicio.us');
  my $res = u('http://mojolicio.us' => {DNT => 1} => 'Hi!');

使用 L<Mojo::UserAgent/"put">  中的 C<PUT>  请求并返回 L<Mojo::Message::Response> 的对象.

=head2 C<x>

  my $dom = x('<div>Hello!</div>');

打开 L<Mojo::DOM> 对象处理 HTML/XML 的输入.

  $ perl -Mojo -E 'say x(b("test.html")->slurp)->at("title")->text'

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
