#!/usr/bin/perl

use File::Basename qw/dirname/;
use lib dirname(__FILE__);
use youtrack;
use jira;
require "config.pl";

use POSIX qw(strftime);
use Data::Dumper;
use Getopt::Long;

my ($skip, $notest, $maxissues, $cookie_file, $debug);
Getopt::Long::Configure('bundling');
GetOptions(
    "skip=i"      => \$skip,
    "notest"      => \$notest,
    "maxissues=i" => \$maxissues,
    "cookie_file=s" => \$cookie_file,
    "debug"       => \$debug
);

my $yt = youtrack->new( Url      => $YTUrl,
                        Token    => $YTtoken,
                        Debug    => $debug );

unless ($yt) {
	die "Could not login to $YTUrl";
}

my $jira = jira->new( Url         => $JiraUrl,
                      Login       => $JiraLogin,
                      Password    => $JiraPassword,
                      Debug       => $debug,
                      Project     => $JiraProject, # Project is optional - it will be used only for getting custom fields
		      cookie_file => $cookie_file,
);

unless ($jira) {
    die "Could not login to $JiraUrl\n";
}

#$jira->addAttachments(IssueKey => 'QMT-8', Files => [ '/tmp/image.png', '/tmp/test test.png' ] ); exit;
#$yt->getAttachments(Key=>'RS-130'); exit;

unless ($notest) {
	print "Let's check JiraPasswords\n";
	foreach (sort keys %JiraPasswords) {
		print $_.' ';
		my $j = jira->new( Url => $JiraUrl, Login => $_, Password => $JiraPasswords{$_} );
		if ($j) {
			print "OK\n";
		} else {
			print "\n";
			undef $JiraPasswords{$_};
		}
	}
	&ifProceed;
}

my $export = $yt->exportIssues(Project => $YTProject);
print "Exported issues: ".scalar @{$export}."\n";

my %users;
foreach my $issue (@{$export}) {
	$users{$issue->{Assignee}} = 1;
	$users{$issue->{reporter}->{login}} = 1;
	foreach (@{$issue->{comments}}) {
		$users{$_->{author}->{login}} = 1;
	}
}
print Dumper(%users) if ($debug);
print "Users found in project\n";
foreach (sort keys %users) {
	my $user = $_;
	print $user;
	if ($User{$user}) {
		$user = $User{$user};
		print " -> $user";
	}
	unless ($jira->getUser(User => $user)) {
		print " -> $JiraLogin";
		$User{$_} = $JiraLogin;
	}
	print "\n";
}

# Do you wish to proceed?
&ifProceed;

my $issuesCount = 0;
foreach my $issue (sort { $a->{numberInProject} <=> $b->{numberInProject} } @{$export}) {
	print "\n-----------------------------------------\n";
	if ($skip && $issue->{numberInProject} <= $skip) {
		print "Skipping issue $YTProject-".$issue->{numberInProject}."\n";
		next;
	}
	$issuesCount++;
	last if ($maxissues && $issuesCount>$maxissues);

	print "Will import issue $YTProject-".$issue->{numberInProject}."\n";

	# Prepare creation time message if exportCreationTime setting is not set
	my $creationTime = scalar localtime ($issue->{created}/1000);
	my $header = "";
	if (not($exportCreationTime)) {
		$header .= "[Created ";
		if ($User{$issue->{reporter}->{login}} eq $JiraLogin) { 
			$header .= "by ".$issue->{reporter}->{login}." "; 
		}
		$header .= $creationTime;
	$header .= "]\n";
	}
	
	my %import = ( project => { key => $JiraProject },
	               issuetype => { name => $Type{$issue->{Type}} || $issue->{Type} },
                   assignee => { name => $User{$issue->{Assignee}} || $issue->{Assignee} },
                   reporter => { name => $User{$issue->{reporter}->{login}} || $issue->{reporter}->{login} },
                   summary => $issue->{summary},
                   description => $header.$issue->{description},
                   priority => { name => $Priority{$issue->{Priority}} || $issue->{Priority} || 'Medium' }
	);

	# Let's check through custom fields
	my %custom;
	foreach my $field (keys %CustomFields) {
		if (defined $issue->{$field}) {
			$custom{$CustomFields{$field}} = $issue->{$field};
		}
	}
	
	# Add YouTrack original creation date field	
	if ($exportCreationTime) {
		my %dateTimeFormats = (
			RFC822 => "%a, %d %b %Y %H:%M:%S %z",
			RFC3389 => "%Y-%m-%dT%H:%M:%S%z",
			ISO8601 => "%FT%T%z",
			GOST7.0.64 => "%Y%m%dT%H%M%S%z",
			JIRA8601 => "%FT%T.00%z"
		);
		$custom{$creationTimeCustomFieldName} = strftime $dateTimeFormats{"$creationDateTimeFormat"}, localtime ($issue->{created}/1000);
	}

	# Let's check for labels
	if ($exportTags eq 'true') {
		my $tags = $yt->getTags(IssueKey => $issue->{id});
		if (@{$tags}) {
			$import{labels} = $tags;
			print "Found tags: ".Dumper($tags) if ($debug);
		}
	}

	my $key = $jira->createIssue(Issue => \%import, CustomFields => \%custom) || die "Error while creating issue";
	print "Created issue $key\n";

	if ($key =~ /^[A-Z]+-(\d+)$/) {
		if ( $1 < $issue->{numberInProject} && ($issue->{numberInProject} - $1) <= $maximumKeyGap ) {
			print "We're having a gap and will delete the issue\n";
			unless ($jira->deleteIssue(Key => $key)) {
				die "Error while deleting the issue $key";
			}
			$issuesCount--;
			redo;
		}
	} else {
		die "Wrong issue key $key";
	}

	# Transition
	if ($Status{$issue->{State}}) {
		print "\nChanging status to ".$Status{$issue->{State}}."\n";
		unless ($jira->doTransition(Key => $key, Status => $Status{$issue->{State}})) {
			die "Failed doing transition";
		}
	}

	# Resolution
	if ($StatusToResolution{$issue->{State}}) {
		print "\nChanging resolution to ".$StatusToResolution{$issue->{State}}."\n";
		unless ($jira->changeFields(Key => $key, Fields => { 'Resolution' => $StatusToResolution{$issue->{State}} } )) {
			die "Failed updating fields"
		}
	}


	# Create comments
	print "\nCreating comments\n";
	foreach (@{$issue->{comments}}) {
		my $author = $User{$_->{author}} || $_->{author};
		my $date = scalar localtime ($_->{created}/1000);
		my $text = $_->{text};
		# Change the links to users
		$text =~ s/[^a-z]\@(\S+)/\[\~$1\]/;
		$text =~ s/^.?\@(\S+)/\[\~$1\]/;
		my $header;
		if ( $JiraPasswords{$author} ) {
			$header = "[ $date ]\n";
			$text = $header.$text;
			my $comment = $jira->createComment(IssueKey => $key, Body => $text, Login => $author, Password => $JiraPasswords{$author}) || die "Error creating comment";
		} else {
			$header = "[ ".$_->{author}." $date ]\n";
			$text = $header.$text;
			my $comment = $jira->createComment(IssueKey => $key, Body => $text) || die "Error creating comment";
		}
	}

	# createAttachments
	if ($exportAttachments eq 'true') {
		print "Check for attachments\n";
		my $attachments = $yt->getAttachments(IssueKey => $YTProject.'-'.$issue->{numberInProject});
		print Dumper($attachments) if ($debug);
		if (@{$attachments}) {
			print "Uploading ".scalar @{$attachments}." files\n";
			unless ($jira->addAttachments(IssueKey => $key, Files => $attachments)) {
				die "Cannot upload attachment to $key";
			}
		}
	}

	# create Issue Links
	if ($exportLinks eq 'true') {
		my $links = $yt->getIssueLinks(IssueKey => $YTProject.'-'.$issue->{numberInProject});
		foreach my $link (@{$links}) {
		    $link->{inwardIssue}->{key} = $key if $link->{inwardIssue}->{key} eq $YTProject.'-'.$issue->{numberInProject};
		    $link->{outwardIssue}->{key} = $key if $link->{outwardIssue}->{key} eq $YTProject.'-'.$issue->{numberInProject};
		    if (defined $IssueLinks{$link->{type}->{name}}) {
        		$link->{type}->{name} = $IssueLinks{$link->{type}->{name}};
    		} else {
        		next;
    		}
		    print "Creating link between ".$link->{outwardIssue}->{key}." and ".$link->{inwardIssue}->{key}."\n";
    		print Dumper($link) if ($debug);
    		if ($jira->createIssueLink( Link => $link )) {
        		print " Done\n";
    		} else {
        		print " Failed. Most likely the second issue is not migrated yet\n";
    		}
		}		
	}
}

sub ifProceed {
	print "\nProceed? (y/N) ";
	my $input = <>;
	chomp $input;
	exit unless (lc($input) eq 'y');
}
