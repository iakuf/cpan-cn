package Mojo::Collection;
use Mojo::Base -strict;
use overload
  bool     => sub { !!@{shift()} },
  '""'     => sub { shift->join("\n") },
  fallback => 1;

use Carp 'croak';
use Exporter 'import';
use List::Util;
use Mojo::ByteStream;
use Scalar::Util 'blessed';

our @EXPORT_OK = ('c');

sub AUTOLOAD {
  my $self = shift;
  my ($package, $method) = split /::(\w+)$/, our $AUTOLOAD;
  croak "Undefined subroutine &${package}::$method called"
    unless blessed $self && $self->isa(__PACKAGE__);
  return $self->pluck($method, @_);
}

sub DESTROY { }

sub c { __PACKAGE__->new(@_) }

sub compact {
  shift->grep(sub { length($_ // '') });
}

sub each {
  my ($self, $cb) = @_;
  return @$self unless $cb;
  my $i = 1;
  $_->$cb($i++) for @$self;
  return $self;
}

sub first {
  my ($self, $cb) = @_;
  return $self->[0] unless $cb;
  return List::Util::first { $cb->($_) } @$self if ref $cb eq 'CODE';
  return List::Util::first { $_ =~ $cb } @$self;
}

sub flatten { $_[0]->new(_flatten(@{$_[0]})) }

sub grep {
  my ($self, $cb) = @_;
  return $self->new(grep { $cb->($_) } @$self) if ref $cb eq 'CODE';
  return $self->new(grep { $_ =~ $cb } @$self);
}

sub join {
  Mojo::ByteStream->new(join $_[1] // '', map {"$_"} @{$_[0]});
}

sub last { shift->[-1] }

sub map {
  my ($self, $cb) = @_;
  return $self->new(map { $_->$cb } @$self);
}

sub new {
  my $class = shift;
  return bless [@_], ref $class || $class;
}

sub pluck {
  my ($self, $method, @args) = @_;
  return $self->map(sub { $_->$method(@args) });
}

sub reverse { $_[0]->new(reverse @{$_[0]}) }

sub shuffle { $_[0]->new(List::Util::shuffle @{$_[0]}) }

sub size { scalar @{$_[0]} }

sub slice {
  my $self = shift;
  return $self->new(@$self[@_]);
}

sub sort {
  my ($self, $cb) = @_;
  return $self->new($cb ? sort { $a->$cb($b) } @$self : sort @$self);
}

sub tap { shift->Mojo::Base::tap(@_) }

sub uniq {
  my %seen;
  return shift->grep(sub { !$seen{$_}++ });
}

sub _flatten {
  map { _ref($_) ? _flatten(@$_) : $_ } @_;
}

sub _ref { ref $_[0] eq 'ARRAY' || blessed $_[0] && $_[0]->isa(__PACKAGE__) }

1;

=encoding utf8

=head1 NAME

Mojo::Collection - Collection

=head1 SYNOPSIS

  use Mojo::Collection;

  # 操作 collection
  my $collection = Mojo::Collection->new(qw(just works));
  unshift @$collection, 'it';

  # 方法链 
  $collection->map(sub { ucfirst })->shuffle->each(sub {
    my ($word, $count) = @_;
    say "$count: $word";
  });

  # collection 中的对象序列化成字符串
  say $collection->join("\n");
  say "$collection";

  # 使用替代的选择构造函数
  use Mojo::Collection 'c';
  c(qw(a b c))->join('/')->url_escape->say;

=head1 DESCRIPTION

L<Mojo::Collection> 是基于数组的容器集.

  # 直接访问数组通过操作集合
  my $collection = Mojo::Collection->new(1 .. 25);
  $collection->[23] += 100;
  say for @$collection;

=head1 FUNCTIONS

L<Mojo::Collection> 实现了以下功能, 这些功能可以单独导入. 

=head2 c

  my $collection = c(1, 2, 3);

构造一个新的基于数组的 L<Mojo::Collection> 对象.

=head1 METHODS

L<Mojo::Collection> 有下列的方法.

=head2 compact

  my $new = $collection->compact;

创建一个新的  L<Mojo::Collection> 对象, 并且全部的元素必须都定义过, 不能是空的字符.

=head2 each

  my @elements = $collection->each;
  $collection  = $collection->each(sub {...});

返回集合中所有元素的列表, 并操作回调中的每个元素. 该元素会做为回调函数的第一个参数传递, 也可为 C<$_> 取得.

  $collection->each(sub {
    my ($e, $count) = @_;
    say "$count: $e";
  });

=head2 first

  my $first = $collection->first;
  my $first = $collection->first(qr/foo/);
  my $first = $collection->first(sub {...});

Evaluate regular expression or callback for each element in collection and
return the first one that matched the regular expression, or for which the
callback returned true. The element will be the first argument passed to the
callback and is also available as C<$_>.

  my $five = $collection->first(sub { $_ == 5 });

=head2 flatten

  my $new = $collection->flatten;

Flatten nested collections/arrays recursively and create a new collection with
all elements.

=head2 grep

  my $new = $collection->grep(qr/foo/);
  my $new = $collection->grep(sub {...});

Evaluate regular expression or callback for each element in collection and
create a new collection with all elements that matched the regular expression,
or for which the callback returned true. The element will be the first
argument passed to the callback and is also available as C<$_>.

  my $interesting = $collection->grep(qr/mojo/i);

=head2 join

  my $stream = $collection->join;
  my $stream = $collection->join("\n");

Turn collection into L<Mojo::ByteStream>.

  $collection->join("\n")->say;

=head2 last

  my $last = $collection->last;

Return the last element in collection.

=head2 map

  my $new = $collection->map(sub {...});

Evaluate callback for each element in collection and create a new collection
from the results. The element will be the first argument passed to the
callback and is also available as C<$_>.

  my $doubled = $collection->map(sub { $_ * 2 });

=head2 new

  my $collection = Mojo::Collection->new(1, 2, 3);

Construct a new array-based L<Mojo::Collection> object.

=head2 pluck

  my $new = $collection->pluck($method);
  my $new = $collection->pluck($method, @args);

Call method on each element in collection and create a new collection from the
results.

  # Equal to but more convenient than
  my $new = $collection->map(sub { $_->$method(@args) });

=head2 reverse

  my $new = $collection->reverse;

创建一个新的 collection 的对象, 这个中包含反转过的顺序的元素.

=head2 slice

  my $new = $collection->slice(4 .. 7);

创建一个新的 collection 的对象, 这个中包含你切片选择的元素.

=head2 shuffle

  my $new = $collection->shuffle;

创建一个新的 collection 的对象, 这个中的元素的顺序是完全打乱的.

=head2 size

  my $size = $collection->size;

返回对象中元素的数量.

=head2 sort

  my $new = $collection->sort;
  my $new = $collection->sort(sub {...});

从结果中返回一个新的 collection 对象, 这个结果是基于给的回调返回的值的排序.

  # Sort values case insensitive
  my $insensitive = $collection->sort(sub { uc($a) cmp uc($b) });

=head2 tap

  $collection = $collection->tap(sub {...});

L<Mojo::Base/"tap"> 的别名.

=head2 uniq

  my $new = $collection->uniq;

创建一个新的没有重复元素的 collection 对象.

=head1 AUTOLOAD

In addition to the L</"METHODS"> above, you can also call methods provided by
all elements in the collection directly and create a new collection from the
results, similar to L</"pluck">.

  # "<h2>Test1</h2><h2>Test2</h2>"
   my $collection = Mojo::Collection->new(
     Mojo::DOM->new("<h1>1</h1>"), Mojo::DOM->new("<h1>2</h1>"));
   $collection->at('h1')->type('h2')->prepend_content('Test')->join;

=head1 OPERATORS

L<Mojo::Collection> overloads the following operators.

=head2 bool

  my $bool = !!$collection;

True or false, depending on if the collection is empty.

=head2 stringify

  my $str = "$collection";

Stringify elements in collection and L</"join"> them with newlines.

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
