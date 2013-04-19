=pod

=encoding utf-8

=head1 NAME

简简单单讲sort

=head1 SYNOPSIS 

仙子注：本文档和仙子前面的2篇文档"简简单单讲grep"，"简简单单讲map"，都译自网络，加上仙子自己的解释整理而成。原文档出自：

http://web.archive.org/web/20041123005900/http://www.raycosoft.com/rayco/support/perl_tutor.html

文档的Author是位Perl Hacker，曾在Microsoft和T-Mobile工作。要理解他的全部Code并不容易，也许偶讲的也不是很清楚，所以，读者自己也要多动脑筋哦。



=head1 sort 函数

    sort LIST
    sort BLOCK LIST
    sort SUBNAME LIST

sort 的用法有如上 3 种形式。它对 LIST 进行排序，并返回排序后的列表。假如忽略了 SUBNAME 或 BLOCK，sort 按标准字串比较顺序来进行（例如ASCII顺序）。如果指定了SUBNAME，它实际上是个子函数的名字，该子函数对比2个列表元素，并返回一个小于，等于，或大于0的整数，这依赖于元素以何种顺序来sort（升序，恒等，或降序）。也可提供一个BLOCK作为匿名子函数来代替SUBNAME，效果是一样的。

被比较的2个元素，会被临时赋值给变量 $a 和 $b。它们以引用传递，所以不要修改 $a 或 $b。假如使用子函数，它不能是递归函数。

=head1 用法示例

=over 11 

=item  以数字顺序sort

    @array = (8, 2, 32, 1, 4, 16);
    print join(' ', sort { $a <=> $b } @array), "\n";

打印结果是：

    1 2 4 8 16 32

与之一样的是：

    sub numerically { $a <=> $b };
    print join(' ', sort numerically @array), "\n";

这个很容易理解哦，它只是按自然数的顺序进行sort，偶就不细讲了。

=item 以ASCII顺序（非字典顺序）进行sort

    @languages = qw(fortran lisp c c++ Perl python java);
    print join(' ', sort @languages), "\n";

打印结果：

    Perl c c++ fortran java lisp python

这等同于：

    print join(' ', sort { $a cmp $b } @languages), "\n";

按ASCII的顺序进行排序，也没什么说的哦。

注意，如果对数字按ASCII顺序进行sort的话，结果可能与你想的不同：

    print join(' ', sort 1 .. 11), "\n";
    1 10 11 2 3 4 5 6 7 8 9

=item  Perl 中以字典顺序 sort

    use locale;
    @array = qw(ASCII ascap at_large atlarge A ARP arp);
    @sorted = sort { ($da = lc $a) =~ s/[\W_]+//g;
                     ($db = lc $b) =~ s/[\W_]+//g;
                     $da cmp $db;
                   } @array;
    print "@sorted\n";

打印结果是：

    A ARP arp ascap ASCII atlarge at_large

use locale 是可选的--它让 code 兼容性更好，假如原始数据包含国际字符的话。use locale 影响了cmp,lt,le,ge,gt 和其他一些函数的操作属性--更多细节见 perllocale 的 man page。

注意 atlarge 和 at_large 的顺序在输出时颠倒了，尽管它们的 sort 顺序是一样的（sort 中间的子函数删掉了at_large 中间的下划线）。这点会发生，是因为该示例运行在 perl 5.005_02 上。在 perl 版本 5.6 前，sort 函数不会保护有一样 values 的 keys 的先后顺序。perl 版本 5.6 和更高的版本，会保护这个顺序。

注意哦，不管是 map, grep 还是 sort，都要保护这个临时变量 $_（sort 里是 $a 和 $b）的值，不要去修改它。在该 code 里，在对 $a 或 $b 进行替换操作 s/[\W_]+//g 前，先将它们重新赋值给 $da 和 $db，这样替换操作就不会修改原始元素哦。

=item 以降序 sort

降序 sort 比较简单，把 cmp 或 <=> 前后的操作数调换下位置就可以了。

    sort { $b <=> $a } @array;

或者改变中间的块或子函数的返回值的标记：

    sort { -($a <=> $b) } @array;

或使用 reverse 函数（这有点低效，但也许易读点）：

    reverse sort { $a <=> $b } @array;

=item 使用多个 keys 进行 sort

要以多个 keys 来 sort，将所有以 or 连接起来的比较操作，放在一个子函数里即可。将主要的比较操作放在前面，次要的放在后面。

    # An array of references to anonymous hashes
    @employees = (
        { FIRST => 'Bill',   LAST => 'Gates',     
          SALARY => 600000, AGE => 45 },
        { FIRST => 'George', LAST => 'Tester'     
          SALARY =>  55000, AGE => 29 },
        { FIRST => 'Steve',  LAST => 'Ballmer',   
          SALARY => 600000, AGE => 41 }
        { FIRST => 'Sally',  LAST => 'Developer',
          SALARY =>  55000, AGE => 29 },
        { FIRST => 'Joe',    LAST => 'Tester',   
          SALARY =>  55000, AGE => 29 },
    );
    sub seniority {
        $b->{SALARY}     <=>  $a->{SALARY}
        or $b->{AGE}     <=>  $a->{AGE}
        or $a->{LAST}    cmp  $b->{LAST}
        or $a->{FIRST}   cmp  $b->{FIRST}
    }
    @ranked = sort seniority @employees;
    foreach $emp (@ranked) {
        print "$emp->{SALARY}\t$emp->{AGE}\t$emp->{FIRST}
            $emp->{LAST}\n";
    }

打印结果是：

    600000  45      Bill Gates
    600000  41      Steve Ballmer
    55000   29      Sally Developer
    55000   29      George Tester
    55000   29      Joe Tester

上述 code 看起来很复杂，实际上很容易理解哦。@employees 数组的元素是匿名 hash。匿名 hash 实际上是个引用，可使用 -> 操作符来访问其值，例如$employees[0]->{SALARY}可访问到第一个匿名hash里SALARY对应的值。所以上述各项比较就很清楚了，先比较SALARY的值，再比较AGE的值，再比较LAST的值，最后比较FIRST的值。注意前2项比较是降序的，后2项是升序的，不要搞混了哦。

=item sort 出新数组

    @x = qw(matt elroy jane sally);
    @rank[sort { $x[$a] cmp $x[$b] } 0 .. $#x] = 0 .. $#x;
    print "@rank\n";

打印结果是：

    2 0 1 3

这里是否有点糊涂呀？仔细看就清楚了。0 .. $#x 是个列表，它的值是 @x 数组的下标，这里就是 0 1 2 3。$x[$a] cmp $x[$b] 就是将 @x 里的各个元素，按ASCII顺序进行比较。所以 sort 的结果返回对 @x 的下标进行排序的列表，排序的标准就是该下标对应的 @x 元素的 ASCII 顺序。

还不明白 sort 返回什么？让我们先打印出 @x 里元素的 ASCII 顺序：

    @x = qw(matt elroy jane sally);
    print join ' ',sort { $a cmp $b } @x;

打印结果是：elroy jane matt sally

它们在@x里对应的下标是1 2 0 3，所以上述sort返回的结果就是1 2 0 3这个列表了。@rank[1 2 0 3] = 0 .. $#x 只是个简单的数组赋值操作，所以@rank的结果就是(2 0 1 3)了。

=item 按 keys 对 hash 进行 sort

    %hash = (
            Donald => Knuth, 
            Alan => Turing, 
            John => Neumann,
    );
    @sorted = map { { ($_ => $hash{$_}) } } sort keys %hash;
    foreach $hashref (@sorted) {
        ($key, $value) = each %$hashref;
        print "$key => $value\n";
    }

打印结果是：

    Alan => Turing
    Donald => Knuth
    John => Neumann

上述code不难明白哦。sort keys %hash 按 %hash 的 keys 的 ASCII 顺序返回一个列表，然后用 map 进行计算，注意 map 这里用了双重{{}}，里面的 {} 是个匿名 hash 哦，也就是说map的结果是个匿名hash列表，明白了呀？

所以@sorted数组里的元素就是各个匿名hash，通过%$hashref进行反引用，就可以访问到它们的key/value值了。

=item 按values对hash进行sort

    %hash = ( Elliot => Babbage,
              Charles => Babbage,
              Grace => Hopper,
              Herman => Hollerith
            );
    @sorted = map { { ($_ => $hash{$_}) } }
                  sort { $hash{$a} cmp $hash{$b}
                         or $a cmp $b
                       } keys %hash;
    foreach $hashref (@sorted) {
        ($key, $value) = each %$hashref;
        print "$key => $value\n";
    }

打印结果是：

    Charles => Babbage
    Elliot => Babbage
    Herman => Hollerith
    Grace => Hopper

本文作者如是说，偶觉得很重要：

与hash keys不同，我们不能保证hash values的唯一性。假如你仅根据values来sort hash，那么当你增或删其他values时，有着相同value的2个元素的sort顺序可能会改变。为了求得稳定的结果，应该对value进行主sort，对key进行从sort。

这里{ $hash{$a} cmp $hash{$b} or $a cmp $b } 就先按value再按key进行了2次sort哦，sort返回的结果是排序后的keys列表，然后这个列表再交给map进行计算，返回一个匿名hash列表。访问方法与前面的相同，偶就不详叙了。

=item 对文件里的单词进行sort，并去除重复的

    perl -0777ane '$, = "\n"; \
       @uniq{@F} = (); print sort keys %uniq' file

大家试试这种用法，偶也不是很明白的说，:(

@uniq{@F} = ()使用了hash slice来创建一个hash，它的keys是文件里的唯一单词；该用法在语意上等同于$uniq{ $F[0], $F[1], ... $F[$#F] } = ()。

各选项说明如下：

-0777    -   读入整个文件，而不是单行
-a       -   自动分割模式，将行分割到@F数组
-e       -   从命令行读取和运行脚本
-n       -   逐行遍历文件：while (<>;) { ... }
$,       -   print函数的输出域分割符
file     -   文件名

=item 高效sorting: Orcish算法和Schwartzian转换

对每个key，sort的子函数通常被调用多次。假如非常在意sort的运行时间，可使用Orcish算法或Schwartzian转换，以便每个key仅被计算1次。

考虑如下示例，它根据文件修改日期来sort文件列表。

# 强迫算法--对每个文件要多次访问磁盘
    @sorted = sort { -M $a <=> -M $b } @filenames;

# Orcish算法--在hash里创建keys
    @sorted = sort { ($modtimes{$a} ||= -M $a) <=>
                     ($modtimes{$b} ||= -M $b)
                   } @filenames;

很巧妙的算法，是不是？因为文件的修改日期在脚本运行期间是基本不变的，所以-M运算一次后，把它存起来就可以了呀。偶就经常这么用的，:p

如下是Schwartzian转换的用法：

    @sorted = map( { $_->[0] }   
                   sort( { $a->[1] <=> $b->[1] }
                         map({ [$_, -M] } @filenames)
                       )
                 );

这个code结合用了map,sort分了好几层，记住偶以前提过的方法，从后往前看。map({ [$_, -M] } @filenames)返回一个列表，列表元素是匿名数组，匿名数组的第一个值是文件名，第二个值是文件的修改日期。

sort( { $a->[1] <=> $b->[1] }...再对上述产生的匿名数组列表进行sort，它根据文件的修改日期进行sort。sort返回的结果是经过排序后的匿名数组。

最外围的map( { $_->[0] }...就简单了，它从上述sort产生的匿名数组里提取出文件名。这个文件名就是根据修改日期进行sort过的呀，并且每个文件只运行了一次-M。

这就是著名的Schwartzian转换，这种用法在国外perl用户里很流行。记住仙子告诉你的Schwartzian概念哦，下次就不会被老外laugh at了，:p

本文作者说：

Orcish算法通常更难于编码，并且不如Schwartzian转换文雅。我推荐你使用Schwartzian转换作为可选择的方法。

也请记住基本的优化code的规则：(1)不写code；(2)在使code快速之前，先保证其正确；(3)在使code快速之前，先让它清楚。

=item 根据最后一列来对行进行sort（Schwartzian转换）

假如$str的值如下（每行以\n终结）：

eir    11   9   2   6   3   1   1   81%   63%   13
oos    10   6   4   3   3   0   4   60%   70%   25
hrh    10   6   4   5   1   2   2   60%   70%   15
spp    10   6   4   3   3   1   3   60%   60%   14

按最后1个域的大小进行sort:

    $str = join "\n",
                map { $_->[0] }
                    sort { $a->[1] <=> $b->[1] }
                         map { [ $_, (split)[-1] ] }
                             split /\n/, $str;

打印结果是：

    eir    11   9   2   6   3   1   1   81%   63%   13
    spp    10   6   4   3   3   1   3   60%   60%   14
    hrh    10   6   4   5   1   2   2   60%   70%   15
    oos    10   6   4   3   3   0   4   60%   70%   25

让我们从后往前，一步一步看上述code：

split /\n/, $str; 这里返回一个列表，列表元素就是各个行了。

map { [ $_, (split)[-1] ] } 这里的map求得一个匿名数组列表，匿名数组的值分别是整行，和该行的最后一列。使用Schwartzian转换时，这步是关键哦，记着用map来构造你自己的匿名数组列表，匿名数组的第1个元素是最终需要的值，第2个元素是用于比较的值。

sort { $a->[1] <=> $b->[1] } 对上1步中产生的匿名数组，按第2个元素进行sort，它返回sort后的匿名数组列表。

map { $_->[0] } 对上1步中sort后的匿名数组，提取出第1个元素，也就是整行哦。

$str = join "\n", 把上步中的各行用"\n"连接起来，并赋值给$str。

也许你会说：“怎么这么麻烦呀？偶不想用这种方式。”那么，可用CPAN上的现成模块来代替：

    Use Sort::Fields;
    @sorted = fieldsort [ 6, '2n', '-3n' ] @lines;

CPAN的模块文档很详细的，自己看看呀。

=item 重访高效sorting: Guttman-Rosler转换

考虑如下示例：

    @dates = qw(2001/1/1  2001/07/04  1999/12/25);

你想按日期升序对它们进行排序，哪种方法最有效呢？

最直观的Schwartzian转换可以这样写：

    @sorted = map { $_->[0] }
              sort { $a->[1] <=> $b->[1]
                     or $a->[2] <=> $b->[2]
                     or $a->[3] <=> $b->[3]
                   }
              map { [ $_, split m</>; $_, 3 ] } @dates;

然而，更高效的Guttman-Rosler转换(GRT)这样写：

    @sorted = map { substr $_, 10 }
              sort
              map { m|(\d\d\d\d)/(\d+)/(\d+)|;
                    sprintf "%d-%02d-%02d%s", $1, $2, $3, $_
                  } @dates;

本文作者说：

GRT 方法难于编码，并且比 Schwartzian 转换更难阅读，所以我推荐仅在极端环境下使用 GRT。使用大的数据源，perl 5.005_03 和 linux 2.2.14 进行测试，GRT 比 Schwartzian 转换快 1.7 倍。用 perl 5.005_02 和 windows NT 4.0 SP6 进行测试，GRT 比 Schwartzian 快 2.5 倍。

另外，perl 5.6 及更高版本的 sort 使用 Mergesort 算法，而 5.6 之前的 sort 使用 Quicksort 算法，前者显然快于后者，所以，要想求速度，也要升级你的perl版本哦。

=back

=head1 CPAN上关于sort的一些模块

File::Sort - Sort one or more text files by lines

Sort::Fields - Sort lines using one or more columns as the sort key(s)

Sort::ArbBiLex - Construct sort functions for arbitrary sort orders

Text::BibTeX::BibSort - Generate sort keys for bibliographic entries.

自己在CPAN上search和read哦，偶不详解了，:P
