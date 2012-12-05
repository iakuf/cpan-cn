package MyCPAN::Pod::Parser;
use Pod::Simple::XHTML;
use parent qw/Pod::Simple::XHTML/;
use URI::Escape qw/uri_escape_utf8/;
use Smart::Comments;

sub new {
    my $self = shift->SUPER::new(@_);
    $self->{translated_toc} = +{
        'NAME'                  => '名前',
        'SYNOPSIS'              => '概要',
        'DESCRIPTION'           => '説明',
        'AUTHOR'                => '作者',
        'AUTHORS'               => '作者',
        'OPTION'                => 'オプション',
        'OPTIONS'               => 'オプション',
        'METHOD'                => 'メソッド',
        'METHODS'               => 'メソッド',
        'FUNCTION'              => '関数',
        'FUNCTIONS'             => '関数',
        'EXAMPLE'               => '例',
        'EXAMPLES'              => '例',
        'COPYRIGHT AND LICENSE' => 'コピーライト & ライセンス',
        'COPYRIGHT & LICENSE'   => 'コピーライト & ライセンス',
        'COPYRIGHT'             => 'コピーライト',
        'LICENSE'               => '许可',
        'CAUTION'               => '警告',
        'ACKNOWLEDGEMENTS'      => '謝辞',
        'SUPPORT'               => '支持',
    };
    return $self;
}

# for google source code prettifier
sub start_Verbatim {
    $_[0]{'scratch'} = '<pre class="prettyprint lang-perl">';
}
sub end_Verbatim {
    $_[0]{'scratch'} .= '</pre>';
    $_[0]->emit;
}

sub _end_head {
    $_[0]->{last_head_body} = $_[0]->{scratch};
    $_[0]->{end_head}  = 1;

    my $h = delete $_[0]{in_head};

    my $add = $_[0]->html_h_level;
       $add = 1 unless defined $add;
    $h += $add - 1;

    my $id = $_[0]->idify($_[0]{scratch});
    my $text = $_[0]{scratch};
    # 对于每个段小标题要怎么显示 
    $_[0]{'scratch'} = sprintf(qq{<h$h id="$id"><a href="#$id" class="mojoscroll">TRANHEADSTART%sTRANHEADEND</a></h$h>}, $text);
    $_[0]->emit;
    push @{ $_[0]{'to_index'} }, [$h, $id, $text];
}

sub end_head1       { shift->_end_head(@_); }
sub end_head2       { shift->_end_head(@_); }
sub end_head3       { shift->_end_head(@_); }
sub end_head4       { shift->_end_head(@_); }

sub handle_text {
    my ($self, $text) = @_;
    if ($_[0]->{end_head}-- > 0 && $text =~ /^\((.+)\)$/) {
        # 最初の行の括弧でかこまれたものがあったら、それは翻訳された見出しとみなす
        # 仕様については Pod::L10N を見よ
        $_[0]->{translated_toc}->{$_[0]->{last_head_body}} = $1;
    } else {
        $self->SUPER::handle_text($text);
    }
}

# 处理引导符中因为中文引起的不能定向
sub idify {
    my ($self, $t, $not_unique) = @_;
    for ($t) {
        s/<[^>]+>//g;            # Strip HTML.
        s/&[^;]+;//g;            # Strip entities.
        s/^\s+|\s+$|\s+//;      # Strip white space.
        s/^([^a-zA-Z]+)$/pod$1/; # Prepend "pod" if no valid chars.
#           s/^[^a-zA-Z]+//;         # First char must be a letter.
        s/([^-a-zA-Z0-9_:.]+)/unpack("U*", $1)/eg; # All other chars must be valid.
    }
    return $t if $not_unique;
    my $i = '';
    $i++ while $self->{ids}{"$t$i"}++;
    return "$t$i";
}

sub end_Document {
    my ($self) = @_;
    my $to_index = $self->{'to_index'};

    if ( $self->index && @{$to_index} ) {
        my @out;
        my $level  = 0;
        my $indent = -1;
        my $space  = '';
        my $id     = ' class="pod_toc"';

        for my $h ( @{$to_index}, [0] ) {
            my $target_level = $h->[0];

            # Get to target_level by opening or closing ULs
            if ( $level == $target_level ) {
                $out[-1] .= '</li>';
            }
            elsif ( $level > $target_level ) {
                $out[-1] .= '</li>' if $out[-1] =~ /^\s+<li>/;
                while ( $level > $target_level ) {
                    --$level;
                    push @out, ( '  ' x --$indent ) . '</li>'
                      if @out && $out[-1] =~ m{^\s+<\/ul};
                    push @out, ( '  ' x --$indent ) . "</ul>";
                }
                push @out, ( '  ' x --$indent ) . '</li>' if $level;
            }
            else {
                while ( $level < $target_level ) {
                    ++$level;
                    push @out, ( '  ' x ++$indent ) . '<li>'
                      if @out && $out[-1] =~ /^\s*<ul/;
                    push @out, ( '  ' x ++$indent ) . "<ul$id>";
                    $id = '';
                }
                ++$indent;
            }

            next unless $level;

            $space = '  ' x $indent;
            # 見出しが翻訳されていれば、翻訳されたものをつかう
            my $text = $h->[2];
            if ($self->{translated_toc}->{$text}) {
                $text = $self->{translated_toc}->{$text};
            }
            push @out, sprintf '%s<li><a class="mojoscroll" href="#%s">%s</a>', $space, $h->[1], $text;
        }

        print { $self->{'output_fh'} } join "\n", @out;
    }

    my $output = join( "\n\n", @{ $self->{'output'} } );
    $output =~ s[TRANHEADSTART(.+?)TRANHEADEND][
        if (my $translated = $self->{translated_toc}->{$1}) {
            $translated;
        } else {
            $1;
        }
    ]ge;
    print { $self->{'output_fh'} } qq{\n\n<div class="pod_content_body">$output\n\n</div>};
    @{ $self->{'output'} } = ();
}

1;

