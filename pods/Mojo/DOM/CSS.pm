package Mojo::DOM::CSS;
use Mojo::Base -base;

has 'tree';

my $ESCAPE_RE = qr/\\[^[:xdigit:]]|\\[[:xdigit:]]{1,6}/;
my $ATTR_RE   = qr/
  \[
  ((?:$ESCAPE_RE|[\w\-])+)        # Key
  (?:
    (\W)?                         # Operator
    =
    (?:"((?:\\"|[^"])+)"|(\S+))   # Value
  )?
  \]
/x;
my $CLASS_ID_RE = qr/
  (?:
    (?:\.((?:\\\.|[^\#.])+))   # Class
  |
    (?:\#((?:\\\#|[^.\#])+))   # ID
  )
/x;
my $PSEUDO_CLASS_RE = qr/(?::([\w\-]+)(?:\(((?:\([^)]+\)|[^)])+)\))?)/;
my $TOKEN_RE        = qr/
  (\s*,\s*)?                         # Separator
  ((?:[^[\\:\s,]|$ESCAPE_RE\s?)+)?   # Element
  ($PSEUDO_CLASS_RE*)?               # Pseudoclass
  ((?:$ATTR_RE)*)?                   # Attributes
  (?:
    \s*
    ([>+~])                          # Combinator
  )?
/x;

sub select {
  my $self = shift;

  my @results;
  my $pattern = $self->_compile(shift);
  my $tree    = $self->tree;
  my @queue   = ($tree);
  while (my $current = shift @queue) {
    my $type = $current->[0];

    # Root
    if ($type eq 'root') { unshift @queue, @$current[1 .. $#$current] }

    # Tag
    elsif ($type eq 'tag') {
      unshift @queue, @$current[4 .. $#$current];

      # Try all selectors with element
      for my $part (@$pattern) {
        push(@results, $current) and last
          if $self->_combinator([reverse @$part], $current, $tree);
      }
    }
  }

  return \@results;
}

sub _ancestor {
  my ($self, $selectors, $current, $tree) = @_;
  while ($current = $current->[3]) {
    return undef if $current->[0] eq 'root' || $current eq $tree;
    return 1 if $self->_combinator($selectors, $current, $tree);
  }
  return undef;
}

sub _attr {
  my ($self, $key, $regex, $current) = @_;

  # Ignore namespace prefix
  my $attrs = $current->[2];
  for my $name (keys %$attrs) {
    next unless $name =~ /(?:^|:)$key$/;
    return 1 unless defined $attrs->{$name} && defined $regex;
    return 1 if $attrs->{$name} =~ $regex;
  }

  return undef;
}

sub _combinator {
  my ($self, $selectors, $current, $tree) = @_;

  # Selector
  my @s = @$selectors;
  return undef unless my $combinator = shift @s;
  if ($combinator->[0] ne 'combinator') {
    return undef unless $self->_selector($combinator, $current);
    return 1 unless $combinator = shift @s;
  }

  # " " (ancestor)
  my $c = $combinator->[1];
  if ($c eq ' ') { return undef unless $self->_ancestor(\@s, $current, $tree) }

  # ">" (parent only)
  elsif ($c eq '>') {
    return undef unless $self->_parent(\@s, $current, $tree);
  }

  # "~" (preceding siblings)
  elsif ($c eq '~') {
    return undef unless $self->_sibling(\@s, $current, $tree, 0);
  }

  # "+" (immediately preceding siblings)
  elsif ($c eq '+') {
    return undef unless $self->_sibling(\@s, $current, $tree, 1);
  }

  return 1;
}

sub _compile {
  my ($self, $css) = @_;

  my $pattern = [[]];
  while ($css =~ /$TOKEN_RE/g) {
    my ($separator, $element, $pc, $attrs, $combinator)
      = ($1, $2 // '', $3, $6, $11);

    # Trash
    next unless $separator || $element || $pc || $attrs || $combinator;

    # New selector
    push @$pattern, [] if $separator;
    my $part = $pattern->[-1];

    # Empty combinator
    push @$part, [combinator => ' ']
      if $part->[-1] && $part->[-1][0] ne 'combinator';

    # Selector
    push @$part, ['element'];
    my $selector = $part->[-1];

    # Element
    my $tag = '*';
    $element =~ s/^((?:\\\.|\\\#|[^.#])+)// and $tag = $self->_unescape($1);

    # Tag
    push @$selector, ['tag', $tag];

    # Class or ID
    while ($element =~ /$CLASS_ID_RE/g) {

      # Class
      push @$selector, ['attr', 'class', $self->_regex('~', $1)] if defined $1;

      # ID
      push @$selector, ['attr', 'id', $self->_regex('', $2)] if defined $2;
    }

    # Pseudo classes
    while ($pc =~ /$PSEUDO_CLASS_RE/g) {

      # "not"
      if ($1 eq 'not') {
        my $subpattern = $self->_compile($2)->[-1][-1];
        push @$selector, ['pc', 'not', $subpattern];
      }

      # Everything else
      else { push @$selector, ['pc', $1, $2] }
    }

    # Attributes
    while ($attrs =~ /$ATTR_RE/g) {
      my ($key, $op, $value) = ($self->_unescape($1), $2 // '', $3 // $4);
      push @$selector, ['attr', $key, $self->_regex($op, $value)];
    }

    # Combinator
    push @$part, [combinator => $combinator] if $combinator;
  }

  return $pattern;
}

sub _equation {
  my ($self, $equation) = @_;

  # "even"
  my $num = [1, 1];
  if ($equation =~ /^even$/i) { $num = [2, 2] }

  # "odd"
  elsif ($equation =~ /^odd$/i) { $num = [2, 1] }

  # Equation
  elsif ($equation =~ /(?:(-?(?:\d+)?)?(n))?\s*\+?\s*(-?\s*\d+)?\s*$/i) {
    $num->[0] = defined($1) && length($1) ? $1 : $2 ? 1 : 0;
    $num->[0] = -1 if $num->[0] eq '-';
    $num->[1] = $3 // 0;
    $num->[1] =~ s/\s+//g;
  }

  return $num;
}

sub _parent {
  my ($self, $selectors, $current, $tree) = @_;
  return undef unless my $parent = $current->[3];
  return undef if $parent->[0] eq 'root';
  return $self->_combinator($selectors, $parent, $tree) ? 1 : undef;
}

sub _pc {
  my ($self, $class, $args, $current) = @_;

  # ":first-*"
  if ($class =~ /^first-(?:(child)|of-type)$/) {
    $class = defined $1 ? 'nth-child' : 'nth-of-type';
    $args = 1;
  }

  # ":last-*"
  elsif ($class =~ /^last-(?:(child)|of-type)$/) {
    $class = defined $1 ? 'nth-last-child' : 'nth-last-of-type';
    $args = '-n+1';
  }

  # ":checked"
  if ($class eq 'checked') {
    my $attrs = $current->[2];
    return 1 if exists $attrs->{checked} || exists $attrs->{selected};
  }

  # ":empty"
  elsif ($class eq 'empty') { return 1 unless defined $current->[4] }

  # ":root"
  elsif ($class eq 'root') {
    if (my $parent = $current->[3]) { return 1 if $parent->[0] eq 'root' }
  }

  # ":not"
  elsif ($class eq 'not') { return 1 if !$self->_selector($args, $current) }

  # ":nth-*"
  elsif ($class =~ /^nth-/) {

    # Numbers
    $args = $self->_equation($args) unless ref $args;

    # Siblings
    my $parent = $current->[3];
    my $start = $parent->[0] eq 'root' ? 1 : 4;
    my @siblings;
    my $type = $class =~ /of-type$/ ? $current->[1] : undef;
    for my $i ($start .. $#$parent) {
      my $sibling = $parent->[$i];
      next unless $sibling->[0] eq 'tag';
      next if defined $type && $type ne $sibling->[1];
      push @siblings, $sibling;
    }

    # Reverse
    @siblings = reverse @siblings if $class =~ /^nth-last/;

    # Find
    for my $i (0 .. $#siblings) {
      my $result = $args->[0] * $i + $args->[1];
      next if $result < 1;
      last unless my $sibling = $siblings[$result - 1];
      return 1 if $sibling eq $current;
    }
  }

  # ":only-*"
  elsif ($class =~ /^only-(?:child|(of-type))$/) {
    my $type = $1 ? $current->[1] : undef;

    # Siblings
    my $parent = $current->[3];
    my $start = $parent->[0] eq 'root' ? 1 : 4;
    for my $i ($start .. $#$parent) {
      my $sibling = $parent->[$i];
      next if $sibling->[0] ne 'tag' || $sibling eq $current;
      return undef unless defined $type && $sibling->[1] ne $type;
    }

    # No siblings
    return 1;
  }

  return undef;
}

sub _regex {
  my ($self, $op, $value) = @_;
  return undef unless defined $value;
  $value = quotemeta $self->_unescape($value);

  # "~=" (word)
  return qr/(?:^|.*\s+)$value(?:\s+.*|$)/ if $op eq '~';

  # "*=" (contains)
  return qr/$value/ if $op eq '*';

  # "^=" (begins with)
  return qr/^$value/ if $op eq '^';

  # "$=" (ends with)
  return qr/$value$/ if $op eq '$';

  # Everything else
  return qr/^$value$/;
}

sub _selector {
  my ($self, $selector, $current) = @_;

  for my $s (@$selector[1 .. $#$selector]) {
    my $type = $s->[0];

    # Tag (ignore namespace prefix)
    if ($type eq 'tag') {
      my $tag = $s->[1];
      return undef unless $tag eq '*' || $current->[1] =~ /(?:^|:)$tag$/;
    }

    # Attribute
    elsif ($type eq 'attr') {
      return undef unless $self->_attr(@$s[1, 2], $current);
    }

    # Pseudo class
    elsif ($type eq 'pc') {
      return undef unless $self->_pc(lc $s->[1], $s->[2], $current);
    }
  }

  return 1;
}

sub _sibling {
  my ($self, $selectors, $current, $tree, $immediate) = @_;

  my $parent = $current->[3];
  my $found;
  my $start = $parent->[0] eq 'root' ? 1 : 4;
  for my $e (@$parent[$start .. $#$parent]) {
    return $found if $e eq $current;
    next unless $e->[0] eq 'tag';

    # "+" (immediately preceding sibling)
    if ($immediate) { $found = $self->_combinator($selectors, $e, $tree) }

    # "~" (preceding sibling)
    else { return 1 if $self->_combinator($selectors, $e, $tree) }
  }

  return undef;
}

sub _unescape {
  my ($self, $value) = @_;

  # Remove escaped newlines
  $value =~ s/\\\n//g;

  # Unescape Unicode characters
  $value =~ s/\\([[:xdigit:]]{1,6})\s?/pack('U', hex $1)/ge;

  # Remove backslash
  $value =~ s/\\//g;

  return $value;
}

1;

=encoding utf8

=head1 NAME

Mojo::DOM::CSS - CSS 选择器引擎 

=head1 SYNOPSIS

  use Mojo::DOM::CSS;

  # 从 DOM 树中选择元素
  my $css = Mojo::DOM::CSS->new(tree => $tree);
  my $elements = $css->select('h1, h2, h3');

=head1 DESCRIPTION

这个 L<Mojo::DOM::CSS> 是给 L<Mojo::DOM> 用的 CSS 选择器引擎.

=head1 SELECTORS

支持全部的 CSS 选择，这就是一个独立的 CSS 解析器.

=head1 BASE

最基本的东西

=head2 *

全部的成员元素.

  my $all = $css->select('*');

=head2 E

E 型的元素对象, 注意这个 E 是指的 DOM 中的一个元素的意思，E 是 element 的简写, 英文翻译过来是"元素", 所以element其实就是 html 已经定义的标签元素,例如 div, input, a 等等.
,下面不在重复解释.

  my $title = $css->select('title');

=head2 E.warning

  my $warning = $css->select('div.warning');

在元素 C<E> 中, 找到类名为 "warning" 的元素。

=head2 E#myid

  my $foo = $css->select('div#foo');

在元素 C<E> 中, 找到 C<ID> 为  "myid" 的元素.

=head2 E:not(s)

在元素 C<E> 中不匹配简单的选择器 C<s> 中指定的内容.

  my $others = $css->select('div p:not(:first-child)');


=head1 属性过滤(Attribute Filters)

属性过滤(Attribute Filters)的内容就是 html 元素中的属性,例如 name, id, class 但是不是指的其值, 是指属性本身.

=head2 E[foo]

C<E> 元素有一个 C<foo> 属性, 例如下面有个 a 的元素中有个 href 的属性。

  my $links = $css->select('a[href]');

=head2 E[foo="bar"]

匹配给定的属性是某个特定值的元素.例子中选取了所有 name 属性是 foo 的 input 元素.

  my $fields = $css->select('input[name="foo"]');

=head2 E[foo~="bar"]

元素 E 中有一个 C<foo> 的属性并且是一个以空格分隔的列表值，这是指基中和  C<bar> 相等的一个.


  my $fields = $css->select('input[name~="foo"]');

=head2 E[foo^="bar"]

元素 C<E> 中有一个 C<foo> 的属性值是以 C<bar> 字符开头。

  my $fields = $css->select('input[name^="f"]');

=head2 E[foo$="bar"]

元素 C<E> 中有一个 C<foo> 的属性值是以 C<bar> 字符结束.

  my $fields = $css->select('input[name$="o"]');

=head2 E[foo*="bar"]

元素 C<E> 中有一个 C<foo> 的属性值中包含 C<bar> 的子字符串。

  my $fields = $css->select('input[name*="fo"]');

=head1 表单过滤(Form Filters) ,内容过滤(Content Filters) 和后代过滤(Child Filters)

用于对表单进行过滤, 和内容进行过滤

=head2 E:root

元素 C<E> 的根文档

  my $root = $css->select(':root');

=head2 E:checked

在元素 C<E> 中匹配所有选中的被选中元素(比如一个单选按钮或复选框).

  my $input = $css->select(':checked');

=head2 E:empty

在元素 C<E> 没有子元素或者文本的空元素.

  my $empty = $css->select(':empty');

=head2 E:nth-child(n)

这个和下面几个都是后代过滤(Child Filters)。

在元素 C<E> 中，其父节点的第 n 个子节点,匹配其父元素下的第N个子或奇偶元素.这个选择器和之前说的基础过滤(Basic Filters)中的 eq() 有些类似,不同的地方就是前者是从0开始,后者是从1开始.

  my $third = $css->select('div:nth-child(3)');
  my $odd   = $css->select('div:nth-child(odd)');
  my $even  = $css->select('div:nth-child(even)');
  my $top3  = $css->select('div:nth-child(-n+3)');

=head2 E:nth-last-child(n)

在元素 C<E> 中，在父元素中匹配第 n 个子元素的最后一个.

  my $third    = $css->select('div:nth-last-child(3)');
  my $odd      = $css->select('div:nth-last-child(odd)');
  my $even     = $css->select('div:nth-last-child(even)');
  my $bottom3  = $css->select('div:nth-last-child(-n+3)');

=head2 E:nth-of-type(n)

在元素 C<E> 中，指定类型的  n 个兄弟元素.

  my $third = $css->select('div:nth-of-type(3)');
  my $odd   = $css->select('div:nth-of-type(odd)');
  my $even  = $css->select('div:nth-of-type(even)');
  my $top3  = $css->select('div:nth-of-type(-n+3)');

=head2 E:nth-last-of-type(n)

元素 C<E> 中，指定类型的  n 个兄弟元素中的最后一个.

  my $third    = $css->select('div:nth-last-of-type(3)');
  my $odd      = $css->select('div:nth-last-of-type(odd)');
  my $even     = $css->select('div:nth-last-of-type(even)');
  my $bottom3  = $css->select('div:nth-last-of-type(-n+3)');

=head2 E:first-child

元素 C<E> 中，匹配父元素中找到的第一个子元素.

  my $first = $css->select('div p:first-child');

=head2 E:last-child

元素 C<E> 中，匹配父元素中找到的最后一个子元素.

  my $last = $css->select('div p:last-child');

=head2 E:first-of-type

元素 C<E> 中，匹配到类型的兄弟元素中的第一个.

  my $first = $css->select('div p:first-of-type');

=head2 E:last-of-type

元素 C<E> 中，匹配到类型的兄弟元素中的最后一个.

  my $last = $css->select('div p:last-of-type');

=head2 E:only-child

元素 C<E> 中, 匹配到父元素的唯一的子元素

  my $lonely = $css->select('div p:only-child');

=head2 E:only-of-type

元素 C<E> 中, 匹配到指定类型元素的唯一的兄弟元素

  my $lonely = $css->select('div p:only-of-type');

=head1 层次(Hierarchy)

使用构造的选择符来层层过滤DOM元素.

=head2 E F

在 C<E> 元素有个后代元素 C<F> 。

  my $headlines = $css->select('div h1');

=head2 E E<gt> F

在元素 C<E> 上有个 C<F> 的子元素, 在给定的父元素下匹配所有子元素.

  my $headlines = $css->select('html > body > div > h1');

=head2 E + F

匹配所有紧接在 C<E> 元素后的 C<F> 元素.

  my $second = $css->select('h1 + h2');

=head2 E ~ F

匹配 C<E> 元素之后的所有 C<F> 元素, F 是指兄弟元素。

  my $second = $css->select('h1 ~ h2');

=head2 E, F, G

元素类型只要是 C<E>, C<F>  和  C<G> 这三个都能匹配。

  my $headlines = $css->select('h1, h2, h3');

=head2 E[foo=bar][bar=baz]

在 C<E> 元素中其属性符合条件的所有的属性选择器。

  my $links = $css->select('a[foo^="b"][foo$="ar"]');

=head1 对象的属性

L<Mojo::DOM::CSS> 实现了下列对象的属性 

=head2 tree

  my $tree = $css->tree;
  $css     = $css->tree(['root', [qw(text lalala)]]);

文档对象模型。请注意，这个结构应该非常小心，因为它是非常动态的。

=head1 METHODS

L<Mojo::DOM::CSS> inherits all methods from L<Mojo::Base> and implements the following new ones.

=head2 select

  my $results = $css->select('head > title');

Run CSS selector against C<tree>.

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
