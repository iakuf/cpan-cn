package Mojo::Content::Single;
use Mojo::Base 'Mojo::Content';

use Mojo::Asset::Memory;
use Mojo::Content::MultiPart;

has asset => sub { Mojo::Asset::Memory->new(auto_upgrade => 1) };
has auto_upgrade => 1;

sub new {
  my $self = shift->SUPER::new(@_);
  $self->{read}
    = $self->on(read => sub { $_[0]->asset($_[0]->asset->add_chunk($_[1])) });
  return $self;
}

sub body_contains { shift->asset->contains(shift) >= 0 }

sub body_size {
  my $self = shift;
  return ($self->headers->content_length || 0) if $self->{dynamic};
  return $self->asset->size;
}

sub clone {
  my $self = shift;
  return undef unless my $clone = $self->SUPER::clone();
  return $clone->asset($self->asset);
}

sub get_body_chunk {
  my ($self, $offset) = @_;
  return $self->generate_body_chunk($offset) if $self->{dynamic};
  return $self->asset->get_chunk($offset);
}

sub parse {
  my $self = shift;

  # Parse headers
  $self->_parse_until_body(@_);

  # Parse body
  return $self->SUPER::parse
    unless $self->auto_upgrade && defined $self->boundary;

  # Content needs to be upgraded to multipart
  $self->unsubscribe(read => $self->{read});
  my $multi = Mojo::Content::MultiPart->new($self);
  $self->emit(upgrade => $multi);
  return $multi->parse;
}

1;

=encoding utf8

=head1 NAME

Mojo::Content::Single - HTTP 内容 

=head1 SYNOPSIS

  use Mojo::Content::Single;

  my $single = Mojo::Content::Single->new;
  $single->parse("Content-Length: 12\x0d\x0a\x0d\x0aHello World!");
  say $single->headers->content_length;

=head1 DESCRIPTION

L<Mojo::Content::Single> 是一个 RFC2616 中描述的 HTTP 内容的一个容器 

=head1 EVENTS

L<Mojo::Content::Single> 继承所有 L<Mojo::Content> 的事件并有以下新的一些功能.

=head2 upgrade

  $single->on(upgrade => sub {
    my ($single, $multi) = @_;
    ...
  });

给内容升级成为 L<Mojo::Content::MultiPart> 的对象.

  $single->on(upgrade => sub {
    my ($single, $multi) = @_;
    return unless $multi->headers->content_type =~ /multipart\/([^;]+)/i;
    say "Multipart: $1";
  });

=head1 ATTRIBUTES

L<Mojo::Content::Single> 继承所有 L<Mojo::Content> 的属性并有以下新的一些.

=head2 asset

  my $asset = $single->asset;
  $single   = $single->asset(Mojo::Asset::Memory->new);

实际的内容，如果 C<auto_upgrade> 是打开的话默认是 L<Mojo::Asset::Memory> 对象。

=head2 auto_upgrade

  my $upgrade = $single->auto_upgrade;
  $single     = $single->auto_upgrade(0);

尝试给发现的多段内容自动升级成 L<Mojo::Content::MultiPart> 的对象，默认为 C<1>.

=head1 METHODS

L<Mojo::Content::Single> 继承所有 L<Mojo::Content> 的方法并实现了下列的。

=head2 new

  my $single = Mojo::Content::Single->new;

构造一个新的 L<Mojo::Content::Single> 的对象，并且给 C<read> 的事件订阅指到默认的内容解析上面.

=head2 body_contains

  my $success = $single->body_contains('1234567');

检查内容是否包含特定字符串。

=head2 body_size

  my $size = $single->body_size;

内容大小（以字节为单位）.

=head2 clone

  my $clone = $single->clone;

如果有内容，就克隆内容，没有就返回 C<undef>.

=head2 get_body_chunk

  my $bytes = $single->get_body_chunk(0);

从指定的位置开始取得 chunk 的内容.

=head2 parse

  $single = $single->parse("Content-Length: 12\x0d\x0a\x0d\x0aHello World!");
  my $multi
    = $single->parse("Content-Type: multipart/form-data\x0d\x0a\x0d\x0a");

解析内容块，如果可能的话，升级到  L<Mojo::Content::MultiPart> 的对象.

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
