package Mojo::DOM;
use Mojo::Base -base;
use overload
  '%{}'    => sub { shift->attrs },
  'bool'   => sub {1},
  '""'     => sub { shift->to_xml },
  fallback => 1;

# "Fry: This snow is beautiful. I'm glad global warming never happened.
#  Leela: Actually, it did. But thank God nuclear winter canceled it out."
use Carp 'croak';
use Mojo::Collection;
use Mojo::DOM::CSS;
use Mojo::DOM::HTML;
use Mojo::Util 'squish';
use Scalar::Util qw(blessed weaken);

sub AUTOLOAD {
  my $self = shift;

  my ($package, $method) = our $AUTOLOAD =~ /^([\w:]+)::(\w+)$/;
  croak "Undefined subroutine &${package}::$method called"
    unless blessed $self && $self->isa(__PACKAGE__);

  # Search children of current element
  my $children = $self->children($method);
  return @$children > 1 ? $children : $children->[0] if @$children;
  croak qq{Can't locate object method "$method" via package "$package"};
}

sub DESTROY { }

sub new {
  my $class = shift;
  my $self = bless [Mojo::DOM::HTML->new], ref $class || $class;
  return @_ ? $self->parse(@_) : $self;
}

sub all_text {
  my ($self, $trim) = @_;
  my $tree = $self->tree;
  return _text(_elements($tree), 1, _trim($tree, $trim));
}

sub append { shift->_add(1, @_) }

sub append_content {
  my ($self, $new) = @_;
  my $tree = $self->tree;
  push @$tree, @{_parent($self->_parse("$new"), $tree)};
  return $self;
}

sub at { shift->find(@_)->[0] }

sub attrs {
  my $self = shift;

  # Hash
  my $tree = $self->tree;
  my $attrs = $tree->[0] eq 'root' ? {} : $tree->[2];
  return $attrs unless @_;

  # Get
  return $attrs->{$_[0]} // '' unless @_ > 1 || ref $_[0];

  # Set
  %$attrs = (%$attrs, %{ref $_[0] ? $_[0] : {@_}});

  return $self;
}

sub charset { shift->_html(charset => @_) }

sub children {
  my ($self, $type) = @_;

  my @children;
  my $charset = $self->charset;
  my $xml     = $self->xml;
  my $tree    = $self->tree;
  for my $e (@$tree[($tree->[0] eq 'root' ? 1 : 4) .. $#$tree]) {

    # Make sure child is the right type
    next unless $e->[0] eq 'tag';
    next if defined $type && $e->[1] ne $type;
    push @children, $self->new->charset($charset)->tree($e)->xml($xml);
  }

  return Mojo::Collection->new(@children);
}

sub content_xml {
  my $self = shift;

  # Render children
  my $tree    = $self->tree;
  my $charset = $self->charset;
  my $xml     = $self->xml;
  return join '', map {
    Mojo::DOM::HTML->new(charset => $charset, tree => $_, xml => $xml)->render
  } @$tree[($tree->[0] eq 'root' ? 1 : 4) .. $#$tree];
}

sub find {
  my ($self, $selector) = @_;

  my $charset = $self->charset;
  my $xml     = $self->xml;
  return Mojo::Collection->new(
    map { $self->new->charset($charset)->tree($_)->xml($xml) }
      @{Mojo::DOM::CSS->new(tree => $self->tree)->select($selector)});
}

sub namespace {
  my $self = shift;

  # Extract namespace prefix and search parents
  return '' if (my $current = $self->tree)->[0] eq 'root';
  my $ns = $current->[1] =~ /^(.*?):/ ? "xmlns:$1" : undef;
  while ($current) {
    last if $current->[0] eq 'root';

    # Namespace for prefix
    my $attrs = $current->[2];
    if ($ns) { /^\Q$ns\E$/ and return $attrs->{$_} for keys %$attrs }

    # Namespace attribute
    elsif (defined $attrs->{xmlns}) { return $attrs->{xmlns} }

    # Parent
    $current = $current->[3];
  }

  return '';
}

sub next { shift->_sibling(1) }

sub parent {
  my $self = shift;
  return undef if (my $tree = $self->tree)->[0] eq 'root';
  return $self->new->charset($self->charset)->tree($tree->[3])
    ->xml($self->xml);
}

sub parse {
  my $self = shift;
  $self->[0]->parse(@_);
  return $self;
}

sub prepend { shift->_add(0, @_) }

sub prepend_content {
  my ($self, $new) = @_;
  my $tree = $self->tree;
  splice @$tree, $tree->[0] eq 'root' ? 1 : 4, 0,
    @{_parent($self->_parse("$new"), $tree)};
  return $self;
}

sub previous { shift->_sibling(0) }

sub remove { shift->replace('') }

sub replace {
  my ($self, $new) = @_;

  # Parse
  my $tree = $self->tree;
  if   ($tree->[0] eq 'root') { return $self->xml(undef)->parse($new) }
  else                        { $new = $self->_parse("$new") }

  # Find and replace
  my $parent = $tree->[3];
  my $i = $parent->[0] eq 'root' ? 1 : 4;
  for my $e (@$parent[$i .. $#$parent]) {
    last if $e == $tree;
    $i++;
  }
  splice @$parent, $i, 1, @{_parent($new, $parent)};

  return $self;
}

sub replace_content {
  my ($self, $new) = @_;
  my $tree = $self->tree;
  splice @$tree, $tree->[0] eq 'root' ? 1 : 4, $#$tree,
    @{_parent($self->_parse("$new"), $tree)};
  return $self;
}

sub root {
  my $self = shift;

  my $root = $self->tree;
  while ($root->[0] eq 'tag') {
    last unless my $parent = $root->[3];
    $root = $parent;
  }

  return $self->new->charset($self->charset)->tree($root)->xml($self->xml);
}

sub text {
  my ($self, $trim) = @_;
  my $tree = $self->tree;
  return _text(_elements($tree), 0, _trim($tree, $trim));
}

sub text_after {
  my ($self, $trim) = @_;

  # Find following text elements
  return '' if (my $tree = $self->tree)->[0] eq 'root';
  my (@elements, $started);
  for my $e (@{_elements($tree->[3])}) {
    ++$started and next if $e eq $tree;
    next unless $started;
    last if $e->[0] eq 'tag';
    push @elements, $e;
  }

  return _text(\@elements, 0, _trim($tree->[3], $trim));
}

sub text_before {
  my ($self, $trim) = @_;

  # Find preceding text elements
  return '' if (my $tree = $self->tree)->[0] eq 'root';
  my @elements;
  for my $e (@{_elements($tree->[3])}) {
    last if $e eq $tree;
    push @elements, $e;
    @elements = () if $e->[0] eq 'tag';
  }

  return _text(\@elements, 0, _trim($tree->[3], $trim));
}

sub to_xml { shift->[0]->render }

sub tree { shift->_html(tree => @_) }

sub type {
  my ($self, $type) = @_;

  # Get
  return '' if (my $tree = $self->tree)->[0] eq 'root';
  return $tree->[1] unless $type;

  # Set
  $tree->[1] = $type;

  return $self;
}

sub xml { shift->_html(xml => @_) }

sub _add {
  my ($self, $offset, $new) = @_;

  # Not a tag
  return $self if (my $tree = $self->tree)->[0] eq 'root';

  # Find parent
  my $parent = $tree->[3];
  my $i = $parent->[0] eq 'root' ? 1 : 4;
  for my $e (@$parent[$i .. $#$parent]) {
    last if $e == $tree;
    $i++;
  }

  # Add children
  splice @$parent, $i + $offset, 0, @{_parent($self->_parse("$new"), $parent)};

  return $self;
}

sub _elements {
  return [] unless my $e = shift;
  return [@$e[($e->[0] eq 'root' ? 1 : 4) .. $#$e]];
}

sub _html {
  my ($self, $method) = (shift, shift);
  return $self->[0]->$method unless @_;
  $self->[0]->$method(@_);
  return $self;
}

sub _parent {
  my ($children, $parent) = @_;

  # Link parent to children
  my @new;
  for my $e (@$children[1 .. $#$children]) {
    if ($e->[0] eq 'tag') {
      $e->[3] = $parent;
      weaken $e->[3];
    }
    push @new, $e;
  }

  return \@new;
}

sub _parse {
  my $self = shift;
  Mojo::DOM::HTML->new(charset => $self->charset, xml => $self->xml)
    ->parse(shift)->tree;
}

sub _sibling {
  my ($self, $next) = @_;

  # Make sure we have a parent
  return undef unless my $parent = $self->parent;

  # Find previous or next sibling
  my ($previous, $current);
  for my $child ($parent->children->each) {
    ++$current and next if $child->tree eq $self->tree;
    return $next ? $child : $previous if $current;
    $previous = $child;
  }

  # No siblings
  return undef;
}

sub _text {
  my ($elements, $recurse, $trim) = @_;

  my $text = '';
  for my $e (@$elements) {
    my $type = $e->[0];

    # Nested tag
    my $content = '';
    if ($type eq 'tag' && $recurse) {
      $content = _text(_elements($e), 1, _trim($e, $trim));
    }

    # Text
    elsif ($type eq 'text') { $content = $trim ? squish($e->[1]) : $e->[1] }

    # CDATA or raw text
    elsif ($type eq 'cdata' || $type eq 'raw') { $content = $e->[1] }

    # Add leading whitespace if punctuation allows it
    $content = " $content" if $text =~ /\S\z/ && $content =~ /^[^.!?,;:\s]+/;

    # Trim whitespace blocks
    $text .= $content if $content =~ /\S+/ || !$trim;
  }

  return $text;
}

sub _trim {
  my ($e, $trim) = @_;

  # Disabled
  return 0 unless $e && ($trim = defined $trim ? $trim : 1);

  # Detect "pre" tag
  while ($e->[0] eq 'tag') {
    return 0 if $e->[1] eq 'pre';
    last unless $e = $e->[3];
  }

  return 1;
}

1;

=encoding utf8

=head1 NAME

Mojo::DOM - 基于 CSS 选择器的简单的 HTML/XML DOM 解析模块

=head1 SYNOPSIS

  use Mojo::DOM;

  # 解析
  my $dom = Mojo::DOM->new('<div><p id="a">Test</p><p id="b">123</p></div>');

  # 查找
  say $dom->at('#b')->text;
  say $dom->find('p')->text;
  say $dom->find('[id]')->attr('id');

  # Walk
  say $dom->div->p->[0]->text;
  say $dom->div->children('p')->first->{id};

  # 迭代
  $dom->find('p[id]')->reverse->each(sub { say $_->{id} });

  # 循环
  for my $e ($dom->find('p[id]')->each) {
      say $e->{id}, ':', $e->text;
  }

  # 修改
  $dom->div->p->last->append('<p id="c">456</p>');
  $dom->find(':not(p)')->strip;

  # 渲染
  say $dom;

=head1 DESCRIPTION

L<Mojo::DOM> 是一个简约，比较宽松的 CSS 选择器用以支持 HTML/XML DOM 的解析。它甚至会尝试来解析不正常的 XML，所以你不应该用它来验证是否正确。

=head1 CASE SENSITIVITY

L<Mojo::DOM> 是使用的 HTML 语义，这意味着所有的标签和属性默认为必须小写.

  my $dom = Mojo::DOM->new('<P ID="greeting">Hi!</P>');
  say $dom->at('p')->text;
  say $dom->p->{id};

如果发现是处理 XML，分析器会自动切换成 XML 模式，这时变得区分大小写。

  my $dom = Mojo::DOM->new('<?xml version="1.0"?><P ID="greeting">Hi!</P>');
  say $dom->at('P')->text;
  say $dom->P->{ID};

XML 的检测也可以通过 C<xml> 的方法来禁用.

  # 使用 XML 的语义
  $dom->xml(1);

  # 使用  HTML 的语义
  $dom->xml(0);

=head1 METHODS

L<Mojo::DOM> 继承所有的 L<Mojo::Base> 的方法，并自己实现了下面的方法.

=head2 all_contents

  my $collection = $dom->all_contents;

返回一个 L<Mojo::Collection> 对象包含有着全部的 DOM 结构的节点的 L<Mojo::DOM> 对象.

=head2 all_text

  my $trimmed   = $dom->all_text;
  my $untrimmed = $dom->all_text(0);

从 DOM 结构提取所有的文本内容，默认会启用智能空白微调。

  # "foo bar baz"
  $dom->parse("<div>foo\n<p>bar</p>baz\n</div>")->div->all_text;

  # "foo\nbarbaz\n"
  $dom->parse("<div>foo\n<p>bar</p>baz\n</div>")->div->all_text(0);

=head2 ancestors

  my $collection = $dom->ancestors;
  my $collection = $dom->ancestors('div > p');

通过 CSS 选择器找出这个节点所有的祖先, 使用 L<Mojo::Collection> 对象来包含这些元素的 L<Mojo::DOM> 对象. 

全部的选择的内容是在 L<Mojo::DOM::CSS/"SELECTORS"> 中都支持的.

  # List types of ancestor elements
  say $dom->ancestors->type;

=head2 append

  $dom = $dom->append('<p>I ♥ Mojolicious!</p>');

附加 HTML/XML 片段到这个节点

  # "<div><h1>Test</h1><h2>123</h2></div>"
  $dom->parse('<div><h1>Test</h1></div>')->at('h1')
    ->append('<h2>123</h2>')->root;

  # "<p>Test 123</p>"
  $dom->parse('<p>Test</p>')->at('p')->contents->first->append(' 123')->root;

=head2 append_content

  $dom = $dom->append_content('<p>Hi!</p>');

附加元素内容

  # "<div><h1>AB</h1></div>"
  $dom->parse('<div><h1>A</h1></div>')->at('h1')->append_content('B')->root;

=head2 at

  my $result = $dom->at('html title');

查找并返回  CSS 选择器匹配的第一个元素，返回的内容是 L<Mojo::DOM> 的对象，如果没有发现会返回 C<undef>。支持所有 L<Mojo::DOM::CSS/"SELECTORS"> 的选择。

  # 查找命名空间内定义的第一个 "svg" 元素 
  my $namespace = $dom->at('[xmlns\:svg]')->{'xmlns:svg'};

=head2 attrs

  my $attrs = $dom->attrs;
  my $foo   = $dom->attrs('foo');
  $dom      = $dom->attrs({foo => 'bar'});
  $dom      = $dom->attrs(foo => 'bar');

元素属性

  # 列出 id 的属性
  say $dom->find('*')->attr('id')->compact;

=head2 children

  my $collection = $dom->children;
  my $collection = $dom->children('div > p');

返回一个 L<Mojo::Collection> 包含元素子内容的 L<Mojo::DOM> 对象, 类似 C<find>.

  # 显示随机的子元素类型
  say $dom->children->shuffle->first->type;


=d2 content

  my $str = $dom->content;
  $dom    = $dom->content('<p>I ♥ Mojolicious!</p>');

Return this node's content or replace it with HTML/XML fragment (for C<root>
and C<tag> nodes) or raw content.

  # "<b>Test</b>"
  $dom->parse('<div><b>Test</b></div>')->div->content;

  # "<div><h1>123</h1></div>"
  $dom->parse('<div><h1>Test</h1></div>')->at('h1')->content('123')->root;

  # "<p><i>123</i></p>"
  $dom->parse('<p>Test</p>')->at('p')->content('<i>123</i>')->root;

  # "<div><h1></h1></div>"
  $dom->parse('<div><h1>Test</h1></div>')->at('h1')->content('')->root;

  # " Test "
  $dom->parse('<!-- Test --><br>')->contents->first->content;

  # "<div><!-- 123 -->456</div>"
  $dom->parse('<div><!-- Test -->456</div>')->at('div')
    ->contents->first->content(' 123 ')->root;

=head2 contents

  my $collection = $dom->contents;

Return a L<Mojo::Collection> object containing the child nodes of this element
as L<Mojo::DOM> objects.

  # "<p><b>123</b></p>"
  $dom->parse('<p>Test<b>123</b></p>')->at('p')->contents->first->remove;

  # "<!-- Test -->"
  $dom->parse('<!-- Test --><b>123</b>')->contents->first;


=head2 find

  my $collection = $dom->find('html title');

找到所有 CSS选择器匹配的元素, 并为含有这些元素的 L<Mojo::DOM> 对象集合返回一个 L<Mojo::Collection> 的对象。支持 L<Mojo::DOM::CSS> 的所有选择。

  # 查找特定的元素和提取信息
  my $id = $dom->find('div')->[23]{id};

  # 从多个元素中提取信息
  my @headers = $dom->find('h1, h2, h3')->pluck('text')->each;

=head2 match

  my $result = $dom->match('html title');

Match the CSS selector against this element and return it as a L<Mojo::DOM>
object or return C<undef> if it didn't match. All selectors from
L<Mojo::DOM::CSS/"SELECTORS"> are supported.

=head2 namespace

  my $namespace = $dom->namespace;

查找元素的名字空间.

  # Find namespace for an element with namespace prefix
  my $namespace = $dom->at('svg > svg\:circle')->namespace;

  # Find namespace for an element that may or may not have a namespace prefix
  my $namespace = $dom->at('svg > circle')->namespace;

=head2 next

  my $sibling = $dom->next;

从兄弟元素中返回接下来的一个 L<Mojo::DOM> 的对象。如果没有兄弟元素会返回  C<undef>.

  # "<h2>B</h2>"
  $dom->parse('<div><h1>A</h1><h2>B</h2></div>')->at('h1')->next;

=head2 next_sibling

  my $sibling = $dom->next_sibling;

Return L<Mojo::DOM> object for next sibling node or C<undef> if there are no
more siblings.

  # "456"
  $dom->parse('<p><b>123</b><!-- Test -->456</p>')->at('b')
    ->next_sibling->next_sibling;

=head2 node

  my $type = $dom->node;

This node's type, usually C<cdata>, C<comment>, C<doctype>, C<pi>, C<raw>,
C<root>, C<tag> or C<text>.

=head2 parent

  my $parent = $dom->parent;

从选择的元素中返回父元素的 L<Mojo::DOM> 的对象。如果没有会返回  C<undef>.

=head2 parse

  $dom = $dom->parse('<foo bar="baz">test</foo>');

使用 L<Mojo::DOM::HTML> 来解析 HTML/XML 文档。
Parse HTML/XML document with L<Mojo::DOM::HTML>.

  # 使用 UTF-8 来编码 XML
  my $dom = Mojo::DOM->new->charset('UTF-8')->xml(1)->parse($xml);

=head2 prepend

  $dom = $dom->prepend('<p>Hi!</p>');

前置元素。

  # "<div><h1>A</h1><h2>B</h2></div>"
  $dom->parse('<div><h2>B</h2></div>')->at('h2')->prepend('<h1>A</h1>')->root;

=head2 prepend_content

  $dom = $dom->prepend_content('<p>Hi!</p>');

前置元素的内容。

  # "<div><h2>AB</h2></div>"
  $dom->parse('<div><h2>B</h2></div>')->at('h2')->prepend_content('A')->root;

=head2 previous

  my $sibling = $dom->previous;

返回元素的上一个兄弟元素的  L<Mojo::DOM> 的对象，如果没有会返回 C<undef>. 

  # "<h1>A</h1>"
  $dom->parse('<div><h1>A</h1><h2>B</h2></div>')->at('h2')->previous;

=head2 previous_sibling

  my $sibling = $dom->previous_sibling;

Return L<Mojo::DOM> object for previous sibling node or C<undef> if there are
no more siblings.

  # "123"
  $dom->parse('<p>123<!-- Test --><b>456</b></p>')->at('b')
    ->previous_sibling->previous_sibling;

=head2 remove

  my $old = $dom->remove;

删除这个元素并返回这个元素的 L<Mojo::DOM> 对象.

  # "<div></div>"
  $dom->parse('<div><h1>A</h1></div>')->at('h1')->remove->root;

=head2 replace

  my $old = $dom->replace('<div>test</div>');

替换元素，并返回替换元素的  L<Mojo::DOM> 对象.

  # "<div><h2>B</h2></div>"
  $dom->parse('<div><h1>A</h1></div>')->at('h1')->replace('<h2>B</h2>')->root;

  # "<div></div>"
  $dom->parse('<div><h1>A</h1></div>')->at('h1')->replace('')->root;

=head2 root

  my $root = $dom->root;

返回 L<Mojo::DOM> 对象的 root 节点.

=head2 root

  my $root = $dom->root;

Return L<Mojo::DOM> object for root node.

=head2 siblings

  my $collection = $dom->siblings;
  my $collection = $dom->siblings('div > p');

Find all sibling elements of this node matching the CSS selector and return a
L<Mojo::Collection> object containing these elements as L<Mojo::DOM> objects.
All selectors from L<Mojo::DOM::CSS/"SELECTORS"> are supported.

  # List types of sibling elements
  say $dom->siblings->type;

=head2 strip

  my $parent = $dom->strip;

Remove this element while preserving its content and return L</"parent">.

  # "<div>Test</div>"
  $dom->parse('<div><h1>Test</h1></div>')->at('h1')->strip;

=head2 tap

  $dom = $dom->tap(sub {...});

Alias for L<Mojo::Base/"tap">.

=head2 text

  my $trimmed   = $dom->text;
  my $untrimmed = $dom->text(0);

提取元素的文本内容（不包括子元素），默认启用智能空白微调。

=head2 to_string

  my $str = $dom->to_string;

Render this node and its content to HTML/XML.

  # "<b>Test</b>"
  $dom->parse('<div><b>Test</b></div>')->div->b->to_string;

=head2 tree

  my $tree = $dom->tree;
  $dom     = $dom->tree(['root', [qw(text lalala)]]);

文档对象模型。请注意，这个结构你应该非常小心的使用，因为它是非常动态的。

=head2 type

  my $type = $dom->type;
  $dom     = $dom->type('div');

元素的类型

  # 列出全面的子元素
  say $dom->children->pluck('type');

=head2 val

  my $collection = $dom->val;

Extract values from C<button>, C<input>, C<option>, C<select> or C<textarea>
element and return a L<Mojo::Collection> object containing these values. In
the case of C<select>, find all C<option> elements it contains that have a
C<selected> attribute and extract their values.

  # "b"
  $dom->parse('<input name="a" value="b">')->at('input')->val;

  # "c"
  $dom->parse('<option value="c">Test</option>')->at('option')->val;

  # "d"
  $dom->parse('<option>d</option>')->at('option')->val;

=head2 wrap

  $dom = $dom->wrap('<div></div>');

Wrap HTML/XML fragment around this node, placing it as the last child of the
first innermost element.

  # "<p>123<b>Test</b></p>"
  $dom->parse('<b>Test</b>')->at('b')->wrap('<p>123</p>')->root;

  # "<div><p><b>Test</b></p>123</div>"
  $dom->parse('<b>Test</b>')->at('b')->wrap('<div><p></p>123</div>')->root;

  # "<p><b>Test</b></p><p>123</p>"
  $dom->parse('<b>Test</b>')->at('b')->wrap('<p></p><p>123</p>')->root;

  # "<p><b>Test</b></p>"
  $dom->parse('<p>Test</p>')->at('p')->contents->first->wrap('<b>')->root;

=head2 wrap_content

  $dom = $dom->wrap_content('<div></div>');

Wrap HTML/XML fragment around this node's content, placing it as the last
children of the first innermost element.

  # "<p><b>123Test</b></p>"
  $dom->parse('<p>Test<p>')->at('p')->wrap_content('<b>123</b>')->root;

  # "<p><b>Test</b></p><p>123</p>"
  $dom->parse('<b>Test</b>')->wrap_content('<p></p><p>123</p>');

=head2 xml

  my $bool = $dom->xml;
  $dom     = $dom->xml($bool);

Disable HTML semantics in parser and activate case sensitivity, defaults to
auto detection based on processing instructions.

=head1 AUTOLOAD

In addition to the L</"METHODS"> above, many child elements are also
automatically available as object methods, which return a L<Mojo::DOM> or
L<Mojo::Collection> object, depending on number of children. For more power
and consistent results you can also use L</"children">.

  # "Test"
  $dom->parse('<p>Test</p>')->p->text;

  # "123"
  $dom->parse('<div>Test</div><div>123</div>')->div->[2]->text;

  # "Test"
  $dom->parse('<div>Test</div>')->div->text;

=head1 OPERATORS

L<Mojo::DOM> overloads the following operators.

=head2 array

  my @nodes = @$dom;

Alias for L</"contents">.

  # "<!-- Test -->"
  $dom->parse('<!-- Test --><b>123</b>')->[0];

=head2 bool

  my $bool = !!$dom;

Always true.

=head2 hash

  my %attrs = %$dom;

Alias for L</"attr">.

  # "test"
  $dom->parse('<div id="test">Test</div>')->at('div')->{id};

=head2 stringify

  my $str = "$dom";

Alias for L</"to_string">.

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
