package Moo;

use strictures 1;
use Moo::_Utils;
use B 'perlstring';
use Sub::Defer ();

our $VERSION = '1.000007'; # 1.0.7
$VERSION = eval $VERSION;

require Moo::sification;

our %MAKERS;

sub _install_tracked {
  my ($target, $name, $code) = @_;
  $MAKERS{$target}{exports}{$name} = $code;
  _install_coderef "${target}::${name}" => "Moo::${name}" => $code;
}

sub import {
  my $target = caller;
  my $class = shift;
  strictures->import;
  if ($Moo::Role::INFO{$target} and $Moo::Role::INFO{$target}{is_role}) {
    die "Cannot import Moo into a role";
  }
  return if $MAKERS{$target}; # already exported into this package
  $MAKERS{$target} = { is_class => 1 };
  _install_tracked $target => extends => sub {
    $class->_set_superclasses($target, @_);
    $class->_maybe_reset_handlemoose($target);
    return;
  };
  _install_tracked $target => with => sub {
    require Moo::Role;
    Moo::Role->apply_roles_to_package($target, @_);
    $class->_maybe_reset_handlemoose($target);
  };
  _install_tracked $target => has => sub {
    my ($name_proto, %spec) = @_;
    my $name_isref = ref $name_proto eq 'ARRAY';
    foreach my $name ($name_isref ? @$name_proto : $name_proto) {
      # Note that when $name_proto is an arrayref, each attribute
      # needs a separate \%specs hashref
      my $spec_ref = $name_isref ? +{%spec} : \%spec;
      $class->_constructor_maker_for($target)
            ->register_attribute_specs($name, $spec_ref);
      $class->_accessor_maker_for($target)
            ->generate_method($target, $name, $spec_ref);
      $class->_maybe_reset_handlemoose($target);
    }
    return;
  };
  foreach my $type (qw(before after around)) {
    _install_tracked $target => $type => sub {
      require Class::Method::Modifiers;
      _install_modifier($target, $type, @_);
      return;
    };
  }
  {
    no strict 'refs';
    @{"${target}::ISA"} = do {
      require Moo::Object; ('Moo::Object');
    } unless @{"${target}::ISA"};
  }
  if ($INC{'Moo/HandleMoose.pm'}) {
    Moo::HandleMoose::inject_fake_metaclass_for($target);
  }
}

sub unimport {
  my $target = caller;
  _unimport_coderefs($target, $MAKERS{$target});
}

sub _set_superclasses {
  my $class = shift;
  my $target = shift;
  foreach my $superclass (@_) {
    _load_module($superclass);
    if ($INC{"Role/Tiny.pm"} && $Role::Tiny::INFO{$superclass}) {
      require Carp;
      Carp::croak("Can't extend role '$superclass'");
    }
  }
  # Can't do *{...} = \@_ or 5.10.0's mro.pm stops seeing @ISA
  @{*{_getglob("${target}::ISA")}{ARRAY}} = @_;
  if (my $old = delete $Moo::MAKERS{$target}{constructor}) {
    delete _getstash($target)->{new};
    Moo->_constructor_maker_for($target)
       ->register_attribute_specs(%{$old->all_attribute_specs});
  }
  no warnings 'once'; # piss off. -- mst
  $Moo::HandleMoose::MOUSE{$target} = [
    grep defined, map Mouse::Util::find_meta($_), @_
  ] if $INC{"Mouse.pm"};
}

sub _maybe_reset_handlemoose {
  my ($class, $target) = @_;
  if ($INC{"Moo/HandleMoose.pm"}) {
    Moo::HandleMoose::maybe_reinject_fake_metaclass_for($target);
  }
}

sub _accessor_maker_for {
  my ($class, $target) = @_;
  return unless $MAKERS{$target};
  $MAKERS{$target}{accessor} ||= do {
    my $maker_class = do {
      if (my $m = do {
            if (my $defer_target = 
                  (Sub::Defer::defer_info($target->can('new'))||[])->[0]
              ) {
              my ($pkg) = ($defer_target =~ /^(.*)::[^:]+$/);
              $MAKERS{$pkg} && $MAKERS{$pkg}{accessor};
            } else {
              undef;
            }
          }) {
        ref($m);
      } else {
        require Method::Generate::Accessor;
        'Method::Generate::Accessor'
      }
    };
    $maker_class->new;
  }
}

sub _constructor_maker_for {
  my ($class, $target, $select_super) = @_;
  return unless $MAKERS{$target};
  $MAKERS{$target}{constructor} ||= do {
    require Method::Generate::Constructor;
    require Sub::Defer;
    my ($moo_constructor, $con);

    if ($select_super && $MAKERS{$select_super}) {
      $moo_constructor = 1;
      $con = $MAKERS{$select_super}{constructor};
    } else {
      my $t_new = $target->can('new');
      if ($t_new) {
        if ($t_new == Moo::Object->can('new')) {
          $moo_constructor = 1;
        } elsif (my $defer_target = (Sub::Defer::defer_info($t_new)||[])->[0]) {
          my ($pkg) = ($defer_target =~ /^(.*)::[^:]+$/);
          if ($MAKERS{$pkg}) {
            $moo_constructor = 1;
            $con = $MAKERS{$pkg}{constructor};
          }
        }
      } else {
        $moo_constructor = 1; # no other constructor, make a Moo one
      }
    };
    ($con ? ref($con) : 'Method::Generate::Constructor')
      ->new(
        package => $target,
        accessor_generator => $class->_accessor_maker_for($target),
        construction_string => (
          $moo_constructor
            ? ($con ? $con->construction_string : undef)
            : ('$class->'.$target.'::SUPER::new(@_)')
        ),
        subconstructor_handler => (
          '      if ($Moo::MAKERS{$class}) {'."\n"
          .'        '.$class.'->_constructor_maker_for($class,'.perlstring($target).');'."\n"
          .'        return $class->new(@_)'.";\n"
          .'      } elsif ($INC{"Moose.pm"} and my $meta = Class::MOP::get_metaclass_by_name($class)) {'."\n"
          .'        return $meta->new_object($class->BUILDARGS(@_));'."\n"
          .'      }'."\n"
        ),
      )
      ->install_delayed
      ->register_attribute_specs(%{$con?$con->all_attribute_specs:{}})
  }
}

1;
=pod

=encoding utf-8

=head1 NAME

Moo - 迷你的面向对象 (with Moose compatiblity)

=head1 SYNOPSIS

 package Cat::Food;

 use Moo;

 sub feed_lion {
   my $self = shift;
   my $amount = shift || 1;

   $self->pounds( $self->pounds - $amount );
 }

 has taste => (
   is => 'ro',
 );

 has brand => (
   is  => 'ro',
   isa => sub {
     die "Only SWEET-TREATZ supported!" unless $_[0] eq 'SWEET-TREATZ'
   },
);

 has pounds => (
   is  => 'rw',
   isa => sub { die "$_[0] is too much cat food!" unless $_[0] < 15 },
 );

 1;

And elsewhere:

 my $full = Cat::Food->new(
    taste  => 'DELICIOUS.',
    brand  => 'SWEET-TREATZ',
    pounds => 10,
 );

 $full->feed_lion;

 say $full->pounds;

=head1 DESCRIPTION

这个模块可以理解为超级精减和优化的 L<Moose> 并且支持非常的快速启动,但是它只有你 "所需要的功能" 的集合.

这个也避免了 XS 依赖，好让你可以更加简单的部署，之所以叫  C<Moo> 是因为他提供了几乎所有 L<Moose> 的功能,注，并不完全，大约 2/3 的功能.

这模块不象 L<Mouse> , L<Mouse>主要是想对 L<Moose> 做全面兼容, 所以这个是用元类来提供全面的互操作性 </MOO AND MOOSE>.

如果你想看看 L<Moose> 和 L<Moo> 这些小的差别，可以看看  L</INCOMPATIBILITIES WITH MOOSE>.

=head1 WHY MOO EXISTS

如果你想有一个完整的丰富的面象对象系统的话 L<Moose> 是非常好的东西.

然而，有时你写一个命令行脚本或CGI脚本，快速启动它是必不可少的，或设计作为一个单一的会要通过 L<App::FatPacker> 部署的代码，或者你正在编写一个 CPAN 模块，你希望提供一些属性和功能的制约。

我试过几次使用 L<Mouse>, 但他比 Moo 大最少三倍以上，并且程序运行需要比较多的时间。

如果你不想使用 L<Moose>, 你也不想 "less metaprotocol" 象 L<Mouse>,  你想尽可能少的东西时，这就是 Moo 所能提供的.

更加好的是，如果你以前使用 L<Moose>, 现在换成 L<Moo> 大多的时候能正常的使用.

因些， Moo 就象他的名字，最小的面象对象，你如果要升级成 L<Moose> 也可以很平滑的升级到.

=head1 MOO AND MOOSE

如果 Moo 发现加载了  L<Moose> ,它会自动的注册元类(metaclasses)到你的 L<Moo> 和  L<Moo::Role> 的包中，所以你可以直接使用  L<Moose> 的代码,而不会让人注意到你是不是使用的 L<Moose>.

扩展一个 L<Moose> 的类或 consuming 一个 L<Moose::Role> 的也可以。

So will extending a L<Mouse> class or consuming a L<Mouse::Role> - but note
that we don't provide L<Mouse> metaclasses or metaroles so the other way
around doesn't work. This feature exists for L<Any::Moose> users porting to
L<Moo>; enabling L<Mouse> users to use L<Moo> classes is not a priority for us.

This means that there is no need for anything like L<Any::Moose> for Moo
code - Moo and Moose code should simply interoperate without problem. To
handle L<Mouse> code, you'll likely need an empty Moo role or class consuming
or extending the L<Mouse> stuff since it doesn't register true L<Moose>
metaclasses like L<Moo> does.

If you want types to be upgraded to the L<Moose> types, use
L<MooX::Types::MooseLike> and install the L<MooseX::Types> library to
match the L<MooX::Types::MooseLike> library you're using - L<Moo> will
load the L<MooseX::Types> library and use that type for the newly created
metaclass.

If you need to disable the metaclass creation, add:

  no Moo::sification;

to your code before Moose is loaded, but bear in mind that this switch is
currently global and turns the mechanism off entirely so don't put this
in library code.

=head1 MOO VERSUS ANY::MOOSE

L<Any::Moose> will load L<Mouse> normally, and L<Moose> in a program using
L<Moose> - which theoretically allows you to get the startup time of L<Mouse>
without disadvantaging L<Moose> users.

Sadly, this doesn't entirely work, since the selection is load order dependent
- L<Moo>'s metaclass inflation system explained above in L</MOO AND MOOSE> is
significantly more reliable.

So if you want to write a CPAN module that loads fast or has only pure perl
dependencies but is also fully usable by L<Moose> users, you should be using
L<Moo>.

For a full explanation, see the article
L<http://shadow.cat/blog/matt-s-trout/moo-versus-any-moose> which explains
the differing strategies in more detail and provides a direct example of
where L<Moo> succeeds and L<Any::Moose> fails.

=head1 导入的方法

=head2 new

 Foo::Bar->new( attr1 => 3 );

和其它的面象对象一样，传统的构造函数.

 Foo::Bar->new({ attr1 => 3 });

=head2 BUILDARGS

 sub BUILDARGS {
   my ( $class, @args ) = @_;

   unshift @args, "attr1" if @args % 2 == 1;

   return { @args };
 };

 Foo::Bar->new( 3 );

这个方法默认接受哈希或哈希值引用的命名参数，如果接收的是单个参数和不是哈希会引发错误.

你可以在你的类中重写此方法来处理类型传递给构造函数。
        
这种方法应始终返回哈希值引用的内容。

=head2 BUILD

如果定义了 C<BUILD> 的方法，在你的类构造的时候会自动的调用 C<BUILD> 方法。先从父到子然后实例化对象.通常这是用于验证对象或可能记录。

=head2 DEMOLISH

如果在你你的继承层次中的任何一个地方有 C<DEMOLISH> 的方法， a C<DESTROY> method is created on first object construction which will call C<< $instance->DEMOLISH($in_global_destruction) >> fo    r each C<DEMOLISH> method from child upwards to parents.

Note that the C<DESTROY> method is created on first construction of an object
of your class in order to not add overhead to classes without C<DEMOLISH>
methods; this may prove slightly surprising if you try and define your own.

=head2 does

 if ($foo->does('Some::Role1')) {
   ...
 }

如果对象中有 role 会返回真.

=head1 导入的子函数

=head2 extends

 extends 'Parent::Class';

声明基类, 在多重继承的时候，可以传递到多个父类上(最好使用 role 代替这个功能).

调用 extends 会替换你的父类, 不象 'use base' 只是增加你的父类。

=head2 with

 with 'Some::Role1';

或

 with 'Some::Role1', 'Some::Role2';

组合一个或多个角色( L<Moo::Role> (or L<Role::Tiny>))到当前类. 如果这些角色有冲突的方法，将引发错误。

=head2 has

 has attr => (
   is => 'ro',
 );

声明为类的属性。C<has>的选项如下所示：

=over 2

=item * is

B<required>, 也许还有 C<ro>, C<lazy>, C<rwp> or C<rw>.

C<ro> 的这个功能会让写访问器失效,如果你想写它的话。

这个用于当设置了 C<lazy> 为 1 和设置了  C<builder> 中的 C<_build_${attribute_name}> 来按需生成属性时。

C<rwp> 会生成一个象 C<ro> 一样的访问器，但在写的时候，在内部可以写入，外部调用时不能写入只能读取.

这个 C<rw> 生成标准的 getter/setter 来让属性可以读写.

=item * isa

需要提供个代码块，如果提供了会用于检查传给属性的值。不同于  L<Moose>,  Moo 并没有包含基本的类型系统，所以不能使用 C<< isa => 'Num' >>， 你需要


 isa => sub {
   die "$_[0] is not a number!" unless looks_like_number $_[0]
 },

注意上面这个例子返回值是会被忽略.

L<Sub::Quote aware|/SUB QUOTE AWARE>

由于 L<Moo> 在 coerce 前并没有 C<isa> 检查，如果需要的话，你需要调用默认省略的 BUILDS 。

如果你想使用 L<MooseX::Types> 风格的名字检查，请看  L<MooX::Types::MooseLike>.

这样会让你的 C<isa> 的功能自动的映射到 L<Moose::Meta::TypeConstraint> 的对象上, 设置方式:

  $Moo::HandleMoose::TYPE_MAP{$isa_coderef} = sub {
    require MooseX::Types::Something;
    return MooseX::Types::Something::TypeName();
  };

注意，这个例子纯粹是说明性.

=item * coerce

提供一个代码块，强制转换该属性。基本的想法是做类似如下的内容：

 coerce => sub {
   $_[0] + 1 unless $_[0] % 2
 },

注意，了L<Moo> 总是会触发强制转换：这是允许 C<isa> 只是纯粹是为了错误捕获，所以 C<isa> 只是为了确保返回一个有效的值，然后才会运行 coerce.

L<Sub::Quote aware|/SUB QUOTE AWARE>

=item * handles

给一个字符串.

  handles => 'RobotRole'

这个 C<RobotRole> 是角色(L<Moo::Role>)  定义好的接口变成一个方法列表给 handle。

给一个方法列表

 handles => [ qw( one two ) ]

给一个哈希的引用

 handles => {
   un => 'one',
 }

=item * trigger

这个是个代码引用会在任何这个属性设置的时候调用.这个时间包括构造对象的时候.

代码引用调用的时候会给对象和本属性的值做为参数传过去.

如果你设置这个值为 C<1>, 这时会在 C<$self> 生成一个叫 C<_trigger_${attr_name}> 的触发器方法,这个特性来自 L<MooseX::AttributeShortcuts>.

注意，Moose 好象还传旧的值进去，目前这个还不支持.

L<Sub::Quote aware|/SUB QUOTE AWARE>

=item * C<default>

这个也是一个代码引用, 这个会代码引用会以 $self 做为唯一的参数传成这个代码引用.本功能用于在构造对象时没提供参数时来用于填充属性的默认值 - 或如果属性是设置成 lazy 也会调用这个，当在第一次取属性时，没有提供任何值也会调用.

注意，如果你的 default 这个功能在 new() 的时候使用的其它的属性有可能没有填入，所以你不应该依赖其它参数的存在.

L<Sub::Quote aware|/SUB QUOTE AWARE>

=item * C<predicate>

需要给这个方法一个名字，用于检查本属性的值是否被设置，如果设置了就返回 true.

如果你直接设置成 C<1>, 这个 predicate 会自动以 C<has_${attr_name}> 来做为名字，给你这个对象的属性用于检查值.这些特性来自 L<MooseX::AttributeShortcuts>.

=item * C<builder>

需要给个方法的名字来调用，用于创建属性.就象 default 的功能一样，但不是调用函数.

  $default->($self);

Moo 会调用 

  $self->$builder;

如果你设置为 C<1>, 这个 predicate 会自动的帮你设置 C<_build_${attr_name}> 的名字.这个特性来自 L<MooseX::AttributeShortcuts>.

=item * C<clearer>

这个需要提供一个名字来做为清除这个属性用.

如果设置成 C<1>, 这个 clearer 会自动的使用 C<clear_${attr_name}>  这个名字. 这个特性来自 L<MooseX::AttributeShortcuts>.

=item * C<lazy>

B<Boolean>。 如果你想你的属性在调用的时候才创建，你可以使用这个参数。这个通常用于在 L</builder> 的时候依赖其它的参数时用。

=item * C<required>

B<Boolean>. 设置了这个为真后，必须在对象实例创建的时候设置这个属性。

=item * C<reader>

这个是用于设置一个方法的名字，用于取得本属性的值。如果你喜欢 Java 的风格，你可以命名为 C<get_foo>。

=item * C<writer>

如果在设置这个属性的时候会使用这个方法来设置属性的值。如果你喜欢 Java 的风格，你可以命名为 C<set_foo>.

=item * C<weak_ref>

B<Boolean>.  Set this if you want the reference that the attribute contains to be weakened; use this when circular references are possible, which will cause leaks.

=item * C<init_arg>

Takes the name of the key to look for at instantiation time of the object.  A common use of this is to make an underscored attribute have a non-underscored initialization name. C<undef> means that passing the value in on instantiation is ignored.

=back

=head2 before

 before foo => sub { ... };

在 before 后面指定的方法被调用前，调用本引用的代码. 看  L<< Class::Method::Modifiers/before method(s) => sub { ... } >>  有全部的文档.

=head2 around

 around foo => sub { ... };

在 around 后面指定的方法的前后包着本引用指定的代码。 看 L<< Class::Method::Modifiers/around method(s) => sub { ... } >> 有全部的文档.

=head2 after

 after foo => sub { ... };

在 after 后面指定的方法被调用后，调用本引用的代码. 看  L<< Class::Method::Modifiers/after method(s) => sub { ... } >> 有全部的文档.

=head1 SUB QUOTE AWARE

=begin original

L<Sub::Quote/quote_sub> allows us to create coderefs that are "inlineable," giving us a handy, XS-free speed boost.  Any option that is L<Sub::Quote> aware can take advantage of this.

To do this, you can write

=end original

L<Sub::Quote/quote_sub> 可以让我们用代码引用创造象原生的，让我们更加方便，使用 XS-free 来提升速度. 任何选项都可以在 L<Sub::Quote> 中得到利用.

要做到这一点，你可以写成:


  use Moo;
  use Sub::Quote;

  has foo => (
    is => 'ro',
    isa => quote_sub(q{ die "Not <3" unless $_[0] < 3 })
  );

将内联成

  do {
    local @_ = ($_[0]->{foo});
    die "Not <3" unless $_[0] < 3;
  }

or to avoid localizing @_,

  has foo => (
    is => 'ro',
    isa => quote_sub(q{ my ($val) = @_; die "Not <3" unless $val < 3 })
  );

which will be inlined as

  do {
    my ($val) = ($_[0]->{foo});
    die "Not <3" unless $val < 3;
  }

See L<Sub::Quote> for more information, including how to pass lexical
captures that will also be compiled into the subroutine.

=head1 INCOMPATIBILITIES WITH MOOSE

There is no built-in type system.  C<isa> is verified with a coderef; if you
need complex types, just make a library of coderefs, or better yet, functions
that return quoted subs. L<MooX::Types::MooseLike> provides a similar API
to L<MooseX::Types::Moose> so that you can write

  has days_to_live => (is => 'ro', isa => Int);

and have it work with both; it is hoped that providing only subrefs as an
API will encourage the use of other type systems as well, since it's
probably the weakest part of Moose design-wise.

C<initializer> is not supported in core since the author considers it to be a
bad idea but may be supported by an extension in future. Meanwhile C<trigger> or
C<coerce> are more likely to be able to fulfill your needs.

There is no meta object.  If you need this level of complexity you wanted
L<Moose> - Moo succeeds at being small because it explicitly does not
provide a metaprotocol. However, if you load L<Moose>, then

  Class::MOP::class_of($moo_class_or_role)

will return an appropriate metaclass pre-populated by L<Moo>.

No support for C<super>, C<override>, C<inner>, or C<augment> - the author
considers augment to be a bad idea, and override can be translated:

  override foo => sub {
    ...
    super();
    ...
  };

  around foo => sub {
    my ($orig, $self) = (shift, shift);
    ...
    $self->$orig(@_);
    ...
  };

The C<dump> method is not provided by default. The author suggests loading
L<Devel::Dwarn> into C<main::> (via C<perl -MDevel::Dwarn ...> for example) and
using C<$obj-E<gt>$::Dwarn()> instead.

L</default> only supports coderefs, because doing otherwise is usually a
mistake anyway.

C<lazy_build> is not supported; you are instead encouraged to use the
C<< is => 'lazy' >> option supported by L<Moo> and L<MooseX::AttributeShortcuts>.

C<auto_deref> is not supported since the author considers it a bad idea.

C<documentation> will show up in a L<Moose> metaclass created from your class
but is otherwise ignored. Then again, L<Moose> ignores it as well, so this
is arguably not an incompatibility.

Since C<coerce> does not require C<isa> to be defined but L<Moose> does
require it, the metaclass inflation for coerce alone is a trifle insane
and if you attempt to subtype the result will almost certainly break.

Handling of warnings: when you C<use Moo> we enable FATAL warnings.  The nearest
similar invocation for L<Moose> would be:

  use Moose;
  use warnings FATAL => "all";

Additionally, L<Moo> supports a set of attribute option shortcuts intended to
reduce common boilerplate.  The set of shortcuts is the same as in the L<Moose>
module L<MooseX::AttributeShortcuts> as of its version 0.009+.  So if you:

    package MyClass;
    use Moo;

The nearest L<Moose> invocation would be:

    package MyClass;

    use Moose;
    use warnings FATAL => "all";
    use MooseX::AttributeShortcuts;

or, if you're inheriting from a non-Moose class,

    package MyClass;

    use Moose;
    use MooseX::NonMoose;
    use warnings FATAL => "all";
    use MooseX::AttributeShortcuts;

Finally, Moose requires you to call

    __PACKAGE__->meta->make_immutable;

at the end of your class to get an inlined (i.e. not horribly slow)
constructor. Moo does it automatically the first time ->new is called
on your class.

=head1 SUPPORT

Users' IRC: #moose on irc.perl.org

Development and contribution IRC: #web-simple on irc.perl.org

=head1 AUTHOR

mst - Matt S. Trout (cpan:MSTROUT) <mst@shadowcat.co.uk>

=head1 CONTRIBUTORS

dg - David Leadbeater (cpan:DGL) <dgl@dgl.cx>

frew - Arthur Axel "fREW" Schmidt (cpan:FREW) <frioux@gmail.com>

hobbs - Andrew Rodland (cpan:ARODLAND) <arodland@cpan.org>

jnap - John Napiorkowski (cpan:JJNAPIORK) <jjn1056@yahoo.com>

ribasushi - Peter Rabbitson (cpan:RIBASUSHI) <ribasushi@cpan.org>

chip - Chip Salzenberg (cpan:CHIPS) <chip@pobox.com>

ajgb - Alex J. G. Burzyński (cpan:AJGB) <ajgb@cpan.org>

doy - Jesse Luehrs (cpan:DOY) <doy at tozt dot net>

perigrin - Chris Prather (cpan:PERIGRIN) <chris@prather.org>

Mithaldu - Christian Walde (cpan:MITHALDU) <walde.christian@googlemail.com>

ilmari - Dagfinn Ilmari Mannsåker (cpan:ILMARI) <ilmari@ilmari.org>

tobyink - Toby Inkster (cpan:TOBYINK) <tobyink@cpan.org>

=head1 COPYRIGHT

Copyright (c) 2010-2011 the Moo L</AUTHOR> and L</CONTRIBUTORS>
as listed above.

=head1 LICENSE

This library is free software and may be distributed under the same terms
as perl itself.

=cut
