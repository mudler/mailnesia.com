#!/usr/bin/perl -w

use strict;
use Mojolicious::Lite;
use Captcha::reCAPTCHA;

use FindBin;
use lib "$FindBin::Bin/../lib/";

use Mailnesia;
use Mailnesia::Email;
use Mailnesia::Config;
use Carp qw/cluck/;

=head1 website-pages.pl

script contains all website pages where SQL access is not required.

=cut


my $mailnesia = Mailnesia->new({decode_on_open=>":encoding(UTF-8)"});
my $config    = Mailnesia::Config->new;
my $sitename  = $config->{sitename};
my $siteurl   = $config->{siteurl};
my $private_key = \$config->{recaptcha_private_key};
my $public_key  = \$config->{recaptcha_public_key};

# cookies expire after this amount of seconds
my $cookie_expiration = \$config->{cookie_expiration};

app->mode  ( $mailnesia->{devel} ? "development" : "production");
app->config(hypnotoad => {
        listen    => ['http://127.0.0.1:8081'],
        pid_file  => '/tmp/mailnesia-website-pages.pid',
        workers   => 2,
        accepts   => 0
    });

app->log->info("started, mode: ". app->mode);



=head2 POST /captcha.html

captcha verification

=cut

post '/captcha.html' => sub {
        my $self = shift;

        my $c = Captcha::reCAPTCHA->new;
        my $ip = $self->req->headers->header('X-Forwarded-For');
        my $challenge = $self->param ('recaptcha_challenge_field');
        my $response  = $self->param ('recaptcha_response_field' );

        my $mailbox = $mailnesia->check_mailbox_characters( lc $self->cookie('mailbox'), 1 );

        $self->stash(
                mailnesia => $mailnesia,
                index_url => "/",
                mailbox   => $mailbox
            );

        if ($challenge and $response)
        {
            # Verify submission
            my $result = $c->check_answer(
                    $$private_key, $ip,
                    $challenge, $response
                );

            if ( $result->{is_valid} )
            {
                $config->wipe_mailbox_per_IP_list($ip);

                if ($mailbox)
                {
                    return $self->redirect_to("/mailbox/$mailbox");
                }
                else
                {
                    return $self->render(
                            text   => '<div class="alert-message success">OK, valid response!</div>',
                            layout => 'default'
                        );
                }

            }
            else
            {
                # Error
                return $self->render(
                        text   => '<div class="alert-message error">Invalid response!</div>',
                        layout => 'default',
                        status => 403
                    );
            }
        }
        else
        {
            return $self->render(
                    text   => '<div class="alert-message error">Bad Request</div>',
                    layout => 'default',
                    status => 400
                );
        }



    };




=head2 GET /captcha.html

captcha page shown after too many mailbox opened

=cut

get '/captcha.html' => sub {
        my $self = shift;
        my $c = Captcha::reCAPTCHA->new;
        my $mailbox = $mailnesia->check_mailbox_characters( lc $self->cookie('mailbox'), 1 );

        $self->stash(
                mailnesia => $mailnesia,
                index_url => "/",
                mailbox   => $mailbox
            );

        return $self->render(
                text   => '<div class="alert-message error">It is forbidden to open a large number of mailboxes!  Please fill out the captcha if you insist.</div>
<form action="/captcha.html" method="post">' .
$c->get_html($$public_key) .
'<input type="submit" value="submit" /></form>',
                layout => 'default',
                status => 403
            );


};


=head2 GET /

english main html page

=cut

get '/' => sub {
        my $self = shift;

        return $self->pages('main');

    };

=head2 GET /page.html

all english html pages

=cut

get '/:page.html' => [page => qr/[0-9a-z-]+/i] => { page => 'main' } => sub {
        my $self = shift;
        my $page = $self->param('page');

        return $self->pages($page);

    };

=head2 GET /lang/page.html

all html pages other than english

=cut

get '/:lang/:page.html' => [lang => [keys $mailnesia->{text}->{lang_hash}] ] => {page => 'main'} => sub {
        my $self = shift;
        my $page = $self->param('page');
        my $lang = $self->param('lang');

        return $self->pages($page, $lang);


    };

=head2 GET /lang/

main page other than english

=cut

get '/:lang/' => [lang => [keys $mailnesia->{text}->{lang_hash}] ] => sub {
        my $self = shift;

        my $lang = $self->param('lang');


        if ($lang eq 'en')
        {
            return $self->redirect_to ("/");
        }
        else
        {
            return $self->pages('main', $lang);
        }

    };


=head2 pages

helper function used in requests with and without a language (all pages).

=cut

helper pages => sub {
        my $self = shift;
        my $page = shift;
        my $lang = shift;       # language of the requested page

        # language of phrases
        my $language = lc $1 if
                (
                    $lang ||
                    $self->cookie('language') ||
                    $self->req->headers->header('accept-language') ||
                    "en"
                ) =~ m/^([a-z-]{2,5})/i;

        #language check:
        if ( not exists($mailnesia->{text}->{lang_hash}{$language}) )
        {

            if ( length $language > 2 )
            {
                my $two_letter_language_code = substr $language, 0, 2 ;
                if ( exists($mailnesia->{text}->{lang_hash}{$two_letter_language_code}) )
                {
                    # use the two letter code instead, for ex: en-ca => en
                    $language = $two_letter_language_code;
                }
                else
                {
                    # default language
                    $language = 'en';
                }
            }
            else
            {
                # default language
                $language = 'en';
            }
        }

        #save language for each pageload
        $mailnesia->{language} = $language;

        # and in cookie
        $self->cookie( language => $language, {path => '/', expires => time + $$cookie_expiration} );

        my $mailbox = $mailnesia->check_mailbox_characters( lc $self->cookie('mailbox') );

        # if the cookie was invalid, correct it
        if ($mailbox ne $self->cookie('mailbox'))
        {
            $self->cookie( mailbox  => $mailbox, {path => '/', expires => time + $$cookie_expiration} );
        }

        $self->stash(
                mailnesia => $mailnesia,
                index_url => $language eq "en" ?
                "/" :
                "/$language/",
                mailbox   => $mailbox
            );

        if ($mailnesia->{text}->{pages}->{$page}->{$lang || 'en'}->{body})
        {
            return $self->render
            (
                text   => $mailnesia->{text}->{pages}->{$page}->{$lang || 'en'}->{body},
                layout => 'default'
            );
        }
        else
        {
            return $self->render
            (
                text=>qq{<div class="alert-message warning">}.$mailnesia->message('page_does_not_exist',$page).q{</div>},
                status => 404,
                layout => 'default'
            );
        }
        ;

    };


app->secrets([$mailnesia->random_name_for_testing()]);
app->start;
