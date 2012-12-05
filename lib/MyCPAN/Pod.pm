package MyCPAN::Pod;
use Mojo::Base 'Mojolicious::Controller';

use Mojo::Asset::File;
use Mojo::ByteStream 'b';
use Mojo::DOM;
use Mojo::Util 'url_escape';
use Pod::Simple::HTML;
use Pod::Simple::Search;
use Smart::Comments;
use MyCPAN::Pod::Parser;
use Text::Xslate::Util qw/mark_raw html_escape/;

# 路径
my @PATHS = map {$_ , "$_/pods"} @INC;
unshift @PATHS, "./pods";

sub show {
    my $self = shift;

    # 查找 Pod 模块
    my $module = $self->param('module');
    $module =~ s!/!::!g;

    my $path = Pod::Simple::Search->new->find($module, @PATHS);

    # 重定抽到 CPAN 
    return $self->redirect_to("http://metacpan.org/module/$module")
      unless $path && -r $path;

    # 转换 POD 到 HTML
    open my $file, '<', $path;
    my $html = $self->pod2html($path);

    # 重写链接 
    my $dom     = Mojo::DOM->new("$html");

    ## 重写 headers
    my $url = $self->req->url->clone;

    # 尝试找 title
    my $title = 'Perldoc';
    $dom->find('h1 + p')->first(sub { $title = shift->text });

    ## Combine everything to a proper response
    $self->content_for(perldoc => "$dom");
    my $template = $self->app->renderer->_bundled('perldoc');
    $self->render(inline => $template, title => $title);
    $self->res->headers->content_type('text/html;charset="UTF-8"');
}

sub _pod_to_html {
  return undef unless defined(my $pod = shift);

  # Block
  $pod = $pod->() if ref $pod eq 'CODE';

  # Parser
  my $parser = Pod::Simple::HTML->new;
  $parser->force_title('');
  $parser->html_header_before_title('');
  $parser->html_header_after_title('');
  $parser->html_footer('');

  # Parse
  $parser->output_string(\(my $output));
  return $@ unless eval { $parser->parse_string_document("$pod"); 1 };

  # Filter
  $output =~ s!<a name='___top' class='dummyTopAnchor'\s*?></a>\n!!g;
  $output =~ s!<a class='u'.*?name=".*?"\s*>(.*?)</a>!$1!sg;

  return $output;
}

sub parse_name_section {
    my ($class, $stuff) = @_;
    my $src = do {
        if (ref $stuff) {
            $$stuff;
        } else {
            open my $fh, '<:raw', $stuff or die "Cannot open file $stuff: $!";
            my $src = do { local $/; <$fh> };
            if ($src =~ /^=encoding\s+(euc-jp|utf-?8)/sm) {
                $src = Encode::decode($1, $src);
            }
            $src;
        }
    };
    $src =~ s/=begin\s+original.+?=end\s+original\n//gsm;
    $src =~ s/X<[^>]+>//g;
    $src =~ s/=encoding\s+\S+\n//gsm;
    $src =~ s/\r\n/\n/g;

    my ($package, $description) = ($src =~ m/
        ^=head1\s+(?:NAME|題名|名前|名前\ \(NAME\))[ \t]*\n(?:名前\n)?\s*\n+\s*
        \s*(\S+)(?:\s*-+\s*([^\n]+))?
    /msx);

    $package     =~ s/[A-Z]<(.+?)>/$1/g if $package;        # remove tags
    $description =~ s/[A-Z]<(.+?)>/$1/g if $description;    # remove tags
    return ($package, $description || '');
}

sub pod2html {
    my ($class, $stuff) = @_;
    $stuff or die "missing mandatory argument: $stuff";

    my $parser = MyCPAN::Pod::Parser->new();
    $parser->html_encode_chars(q{&<>"'});
    $parser->accept_targets_as_text('original');
    $parser->html_header(''); # 不要头和结束
    $parser->html_footer('');
    $parser->index(1); # display table of contents
    $parser->perldoc_url_prefix('/perldoc/');
    $parser->output_string(\my $out);
    # $parser->html_h_level(3);

    if (ref $stuff eq 'SCALAR') {
        $parser->parse_string_document($$stuff);
    } else {
        $parser->parse_file($stuff);
    }

    return mark_raw($out);
}


1;

__DATA__
@@ perldoc.html.ep
<!DOCTYPE html>
<html>
  <head>
    <title><%= $title %></title>
    %= stylesheet '/css/prettify-mojo.css'
    %= javascript '/js/prettify.js'
    %= stylesheet begin
      a { color: inherit }
      a:hover { color: #2a2a2a }
      a img { border: 0 }
      body {
        background-color: #f5f6f8;
        color: #445555;
        font: 0.9em 'Helvetica Neue', Helvetica, sans-serif;
        font-weight: normal;
        line-height: 1.5em;
        margin: 0;
      }
      h1, h2, h3 {
        color: #2a2a2a;
        font-size: 1.5em;
        margin: 0;
      }
      h1 a, h2 a, h3 a { text-decoration: none }
      pre {
        background-color: #eee;
        background: url(<%= url_for '/mojolicious-pinstripe.gif' %>);
        -moz-border-radius: 5px;
        border-radius: 5px;
        color: #eee;
        font: 0.8em Consolas, Menlo, Monaco, Courier, monospace;
        line-height: 1.7em;
        text-align: left;
        text-shadow: #333 0 1px 0;
        padding-bottom: 1.5em;
        padding-top: 1.5em;
        white-space: pre-wrap;
      }
      #footer {
        padding-top: 1em;
        text-align: center;
      }
      #perldoc {
        background-color: #fff;
        -moz-border-radius-bottomleft: 5px;
        border-bottom-left-radius: 5px;
        -moz-border-radius-bottomright: 5px;
        border-bottom-right-radius: 5px;
        -moz-box-shadow: 0px 0px 2px #ccc;
        -webkit-box-shadow: 0px 0px 2px #ccc;
        box-shadow: 0px 0px 2px #ccc;
        margin-left: 5em;
        margin-right: 5em;
        padding-top: 70px;
        padding:3em 1em 3em 3em;
        overflow:hidden;zoom:1
      }
      #perldoc > ul:first-of-type a { text-decoration: none }
      #wrapperlicious {
        padding: 2em 7.292%;
        position: relative;
      }
      .pod_toc {
        float: right;
        width: 26.042%;
        background: #f6f6f6;
        border: 1px solid #e1e1e1;
        margin: 1em 0em;
      }
     .pod_content_body{
        width:79%;
        float:left;
     }
    % end
  </head>
  <body onload="prettyPrint()">
    %= include inline => app->renderer->_bundled('mojobar')
    % my $link = begin
      %= link_to shift, shift, class => "mojoscroll"
    % end
    <div id="wrapperlicious">
      <div id="perldoc">
        %= content_for 'perldoc'
      </div>
    </div>
    <div id="footer">
      %= link_to 'http://mojolicio.us' => begin
        %= image '/mojolicious-black.png', alt => 'Mojolicious logo'
      % end
    </div>
  </body>
</html>
