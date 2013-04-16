=pod

=encoding utf-8


# Copyright (C) 2001-2005, The Perl Foundation.
# Translator: Jimmy Zhuo
# Email: zhuomingliang@yahoo.com.cn
# $Id: intro.pod 18689 2007-05-30 15:58:47Z coke $

=head1 名称

docs/intro.pod - Parrot 入门

=head1 欢迎使用 Parrot

本文档给那些考虑为 Parrot 手工编写代码或 Parrot 运行平台的编译器，或者是考
虑参与 Parrot 发展，以及仅仅想知道地球上 Parrot 是为何物的人提供了一份文雅的
Parrot 虚拟机介绍。

=head1 什么是 Parrot?

=head2 虚拟机

Parrot 是一个虚拟机。为了了解什么是虚拟机，考虑当你在用 Perl 之类的语言编写一个
程序的时候发生了什么，然后用适当的解释器去运行它（如 Perl 就是 perl 解释器）。
首先，你用高级语言编写的程序转变成简单的指令，例如 I<获取一个变量 x 的值>，
I<对该值加 2>，I<保持该值到变量 y>，等等。一行高级语言的代码可能会转换成许多行
简单的指令。这个阶段叫做I<编译>。

第二个阶段涉及执行这些简单的指令。一些语言（如 C） 常常编译成 CPU 能理解的指令，
所以能被硬件执行。其它语言，例如 Perl，Python 以及 Java， 常常编译成 CPU 独有的
指令。I<虚拟机>（某些时候也叫I<解释器>）需要执行这些指令。

虽然一个虚拟机的核心作用是有效地执行指令，但它也履行了一些其它职能。其中一个是
抽象化硬件及程序运行平台细节。一旦程序已经编译运行到虚拟机上，它将可以在任何已
实现虚拟机的平台上运行。虚拟机也可以通过允许为程序进行更细致的限制来提供安全、内
存管理功能以及高级语言特性（如对象，数据结构，类型，子程序）。

=head2 设计目标

Parrot 应动态类型语言（如 Perl 和 Python）的明确需求而设计，并要求这些语言写的
程序比用静态语言开发的虚拟机（JVM，.NET）能更高效地运行。Parrot 也被设计成在编
译到它上面的语言之间提供互操作性。理论上，你可以用 Perl 写一个类，用 Python 写
一个子类，然后在 Tcl 程序里面实例化并使用那个子类。

在历史上，Parrot 始于 Perl 6 的运行时间。和 Perl 5 不同，Perl 6 的编译器和运行
时间（VM）要更加清晰地分开。在 2001 年 4 月 Perl 和 Python 要在它们语言下一版本合
作的愚人玩笑后，选择了 I<Parrot> 这个名字。它反映了建立这个虚拟机的含义，即不
仅仅运行 Perl 6，而且也要运行很多其它语言。


=head1 Parrot 的概念和术语

=head2 指令格式

Parrot 目前能接受指令以 4 种方式运行。PIR（Parrot 中间描述）被设计成可以被人编
写和编译器生成。它隐藏了一些底层的细节，例如传递参数到函数的方式。PASM
（Parrot 汇编）低于PIR层 - 它仍然是人类可读写并且可编译器生成的。但是作者必须
关心调用规则和寄存器分配。PAST（Parrot 抽象语法树）使 Parrot 接受抽象语法树格
式输入 - 对语法编译器有用。

上面所有的输入格式在 Parrot 里面被自动转换成 PBC（Parrot 字节码）。这非常像机
器码，但是 Parrot 可以理解它。PBC 无意使其人类可读写，但与其它可以立即开始执行
的方式不同，它不需要经过汇编阶段。Parrot 字节码是平台无关的。

=head2 指令集

Parrot 指令集包含了算术和逻辑运算符，比较和分支/跳转（为实现循环，if...then 结
构，等等），查找和保持全局和局部变量，使用类和对象，调用子程序和方法以及它们的
参数，I/O，线程及更多。

=head2 寄存器和基本数据类型

Parrot 虚拟机基于寄存器。这意味着，像一个硬件 CPU 一样，它有许多个快速存取存储
单元的寄存器。Parrot 有 4 种基本数据类型：整型（I），数字（N)，字符串（S）以及
PMC（P）。它们每个都有 N，叫 I0，I1，..N0..，等等。整型寄存器与 Parrot 运行机
器上的字大小一样，数字寄存器也映射到本地浮点类型。
每个子程序在编译时期决定了寄存器需求数量。

=head2 PMCs

PMC 表示多形态容器（Polymorphic Container）。PMC 描述了任何复杂数据结构
或者类型，包括聚合数据类型（数组，哈希表等等）。PMC 可以为在它上面执行算术，
逻辑，字符串操作实现它固有的行为，允许特定语言行为被引入。PMC 可以编译成
Parrot 可执行的或者在它们需要时候动态加载。

=head2 垃圾回收

Parrot 提供垃圾回收，意味着 Parrot 程序不需要明确地释放内存。它将在不再使用并逢
垃圾回收器运行的时候释放（也就是说，不再引用）。


=head1 获取, 创建和测试 Parrot

=head2 从哪里获得 Parrot

每隔一段时间，编号发行将出现在CPAN。版本发布阶段的时候会有大量的变化。你可以从
SVN 版本库获取最新的 Parrot 拷贝。按照以下方式完成：

  svn co https://svn.perl.org/parrot/trunk parrot

你可以在 L<http://www.parrotcode.org/source.html> 找到更多教程。

=head2 创建 Parrot

创建 Parrot 的第一步是运行 F<Configure.pl> 程序，它根据你的平台来决定如何创建
Parrot。通过输入以下命令来完成：

  perl Configure.pl

一但完成这步，运行 C<make> 程序（有时候是 C<nmake> 或 C<dmake> 或 C<gmake>）。
这步应该会完成，并给你一个可运行 Parrot。

请报告你创建 Parrot 时所遇到的任何问题，以便开发者能修复它们。你可以通过发送
一份包含问题描述信息的邮件到 C<parrotbug@parrotcode.org>。请包含创建过程中生
成的 F<myconfig> 文件以及你观察到的任何错误。

=head2 Parrot 测试套件

Parrot 有广泛的回归测试套件。可以通过输入以下命令来运行：

  make test

可以用你平台上的 make 程序名字替代 make。输入结果看起来像这样：

C:\Perl\bin\perl.exe t\harness --gc-debug --running-make-test
   t\library\*.t  t\op\*.t  t\pmc\*.t  t\run\*.t  t\native_pbc\*.t
   imcc\t\*\*.t  t\dynpmc\*.t  t\p6rules\*.t t\src\*.t t\perl\*.t
t\library\dumper...............ok
t\library\getopt_long..........ok
...
All tests successful, 4 test and 71 subtests skipped.
Files=163, Tests=2719, 192 wallclock secs ( 0.00 cusr +  0.00 csys =  0.00 CPU)

有可能一些测试会失败。如果量比较小的话，那你不需要太多的担心，尤其用的是
从 SVN 库获取的最新 Parrot。但是，不要因为这个而阻止你报告失败的测试，请
用上面所描述的方法来报告遇到的错误。


=head1 几个简单的 Parrot 程序

=head2 Hello world!

创建一个包含以下代码的 F<hello.pir> 文件。

  .sub main
      print "Hello world!\n"
  .end

通过输入以下命令来运行:

  parrot hello.pir

正如所期待的，它将在控制台上显示 C<Hello world!> 文本，并跟着一个换行
（取决于 C<\n>）。

让我们来把程序分离。C<.sub main> 表示后面的指令创建了一个叫 C<main> 的
子程序，一直到 C<.end>。第二行包含了一个 C<print> 指令。这种情况下，我
们调用不同能接受字符串常量的指令。汇编程序负责为我们决定使用哪些不同的
指令。

=head2 使用寄存器

我们可以修改 hello.pir，让它首先保存 C<Hello world!\n> 字符串到一个寄存
器，然后通过 print 指令来使用那个寄存器。

  .sub main
      set S0, "Hello world!\n"
      print S0
  .end

我们在这里明确的规定了使用哪个寄存器。然而，通过用 C<$S0> 替换 C<S0> 的方
式，我们可以委托 Parrot 选择使用哪个寄存器。也可以用 C<=> 符号替代 C<set>
指令。

  .sub main
      $S0 = "Hello world!\n"
      print $S0
  .end

为了让 PIR 更加可读，可以使用命名寄存器。它们最后会映射到真正的数字寄存器。

  .sub main
      .local string hello
      hello = "Hello world!\n"
      print hello
  .end

C<.local> 伪指令表示命名寄存器只在当前编译单元内部需要（也就是，在 C<.sub>
和 C<.end>之间的）。C<.local> 后面是一个类型，可以是 C<int> （即 I 寄存
器），C<float>（即 N 寄存器），C<string>（即 S 寄存器），C<pmc>（即 P 寄存
器）或者是 PMC 类型的名字。

=head2 PIR、PASM 比较

PASM 不处理寄存器分配或者提供命名寄存器支持。它也没有 C<.sub> 和 C<.end> 伪
指令，而是在指令的开始用一个标签替代它们。

=head2 平方和

本例介绍了更多的指令和 PIR 语法，以 C<#> 开头的行是注释。

  .sub main
      # 初始化平方和数字
      .local int maxnum
      maxnum = 10

      # 我们将用一些命名寄存器，请注意可以在一行声明很多同样类型的寄存器
      .local int i, total, temp
      total = 0

      # 循环计算总和
      i = 1
  loop:
      temp = i * i
      total += temp
      inc i
      if i <= maxnum goto loop

      # 输出结果
      print "The sum of the first "
      print maxnum
      print " squares is "
      print total
      print ".\n"
  .end

PIR 提供了少量语法糖来使它看起来比汇编语言更高级。例如：

  temp = i * i


以下仅仅是另一个写起来更像汇编的方式：

  mul temp, i, i

并且:

  if i <= maxnum goto loop

和下面一样:

  le i, maxnum, loop

以及:

  total += temp

和下面一样:

  add total, temp


通常，每当 Parrot 指令修改一个寄存器的内容，它将是编写汇编形式指令的第一个寄
存器。

由于汇编语言通常根据条件分支语句和标签来实现循环和选择，正如上所示。汇编语言
编程使用 goto 不是差的方式。

=head2 递归计算阶乘

这个例子我们定义了一个阶乘函数并递归地调用它以计算阶乘。

  .sub factorial
      # 获取一个输入参数
      .param int n

      # return (n > 1 ? n * factorial(n - 1) : 1)
      .local int result

      if n > 1 goto recurse
      result = 1
      goto return

  recurse:
      $I0 = n - 1
      result = factorial($I0)
      result *= n

  return:
      .return (result)
  .end


  .sub main :main
      .local int f, i

      # 我们将计算 0...10 的阶乘
      i = 0
  loop:
      f = factorial(i)

      print "Factorial of "
      print i
      print " is "
      print f
      print ".\n"

      inc i
      if i <= 10 goto loop
  .end

第一行 C<.param int n> 指明了该子程序有一个整型参数，我们指的是通过名字
C<n> 为子程序其余部分传递参数的寄存器。

下面大部分都已经在前面的例子见过，除了下面这行之外：

  result = factorial($I0)

这行 PIR 实际上相当于几行 PASM。汇编程序建立了描述特征的 PMC，其中包括参数
附带的寄存器。为了提供返回值所在寄存器，一个类似的过程发生了。最后，
C<factorial> 子程序被执行。

在 C<factorial> 子程序的 C<.end> 前面，C<.return> 伪指令用来说明这个值在名叫
C<result> 的寄存器里面，并拷贝到调用程序期望保存返回值的寄存器里面。

在 main 调用 C<factorial> 与在子程序 C<factorial> 自己内部调用 C<factorial>
是一样的。唯一有点不同的是 C<.sub main> 之后的新语法 C<:main>. PIR 默认假设
从文件第一个子程序开始执行。这个行为可以通过标记子程序始于 C<:main> 而改变。

=head2 编译成 PBC

为了把 PIR 编程字节码，使用 C<-o> 标志并且指定一个带 F<.pbc> 扩展的输出文件。

  parrot -o factorial.pbc factorial.pir


=head1 接下来怎么办?

=head2 文档

你下一步要阅读什么文档？这取决于你要用 Parrot 做什么。绝大部分人研究操作符文献
和内置的 PMC 文献都是有益的。如果你打算编写或者编译 PIR，那么有许多 PIR 文档值
得一读。对于写编译器的人，有必要阅读一下编译器 FAQ。如果你想参与 Parrot 发展，
PDDs（Parrot 设计文档）包含了 Parrot 一些内部细节；其它一些文档在代码里面。帮
助 Parrot 发展的一种方式是编写测试代码，有份叫 I<测试 Parrot> 的文档对这有帮助。

=head2 Parrot 邮件列表

大部分 Parrot 开发和讨论都在 parrot-porters 邮件列表。你可以用过发送一份邮件到
C<subscribe@perl.org[/email]> 或者到
L<http://www.nntp.perl.org/group/perl.perl6.internals> 阅读 NNTP 存档。

=head2 IRC

Parrot IRC 频道位于 ire.perl.org 上的 C<#parrot>。供选择的 IRC 服务器在
irc.pobox.com 或者 irc.rhizomatic.net。

=cut
