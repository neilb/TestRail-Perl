package TestRail::API;
{
    $TestRail::API::VERSION = '0.007';
}

=head1 NAME

TestRail::API - Provides an interface to TestRail's REST api via HTTP

=head1 SYNOPSIS

    use TestRail::API;

    my $tr = TestRail::API->new($username, $password, $host);

=head1 DESCRIPTION

C<TestRail::API> provides methods to access an existing TestRail account using API v2.  You can then do things like look up tests, set statuses and create runs from lists of cases.
It is by no means exhaustively implementing every TestRail API function.

=cut


use strict;
use warnings;
use Carp;
use Scalar::Util 'reftype';
use Clone 'clone';
use Try::Tiny;

use JSON::XS;
use HTTP::Request;
use LWP::UserAgent;

=head1 CONSTRUCTOR

=head2 B<new (api_url, user, password)>

Creates new C<TestRail::API> object.

=over 4

=item STRING C<API URL> - base url for your TestRail api server.

=item STRING C<USER> - Your testRail User.

=item STRING C<PASSWORD> - Your TestRail password.

=item BOOLEAN C<DEBUG> - Print the JSON responses from TL with your requests.

=back

Returns C<TestRail::API> object if login is successful.

    my $tr = TestRail::API->new('http://tr.test/testrail', 'moo','M000000!');

=cut

sub new {
    my ($class,$apiurl,$user,$pass,$debug) = @_;
    $user //= $ENV{'TESTRAIL_USER'};
    $pass //= $ENV{'TESTRAIL_PASSWORD'};
    $debug //= 0;

    my $self = {
        user             => $user,
        pass             => $pass,
        apiurl           => $apiurl,
        debug            => $debug,
        testtree         => [],
        flattree         => [],
        user_cache       => [],
        type_cache       => [],
        default_request  => undef,
        browser          => new LWP::UserAgent()
    };

    #Create default request to pass on to LWP::UserAgent
    $self->{'default_request'} = new HTTP::Request();
    $self->{'default_request'}->authorization_basic($user,$pass);

    bless $self, $class;
    return $self;
}

#EZ access of obj vars
sub browser {$_[0]->{'browser'}}
sub apiurl {$_[0]->{'apiurl'}}
sub debug {$_[0]->{'debug'}}

#Convenient JSON-HTTP fetcher
sub _doRequest {
    my ($self,$path,$method,$data) = @_;
    my $req = clone $self->{'default_request'};
    $method //= 'GET';

    $req->method($method);
    $req->url($self->apiurl.'/'.$path);

    warn "$method ".$self->apiurl."/$path" if $self->debug;

    #Data sent is JSON
    my $content = $data ? encode_json($data) : '';

    $req->content($content);
    $req->header( "Content-Type" => "application/json" );

    my $response = $self->browser->request($req);

    if ($response->code == 403) {
        warn "ERROR: Access Denied.";
        return 0;
    }
    if ($response->code != 200) {
        warn "ERROR: Arguments Bad: ".$response->content;
        return 0;
    }

    try {
        return decode_json($response->content);
    } catch {
        if ($response->code == 200 && !$response->content) {
            return 1; #This function probably just returns no data
        } else {
            warn "ERROR: Malformed JSON returned by API.";
            warn $@;
            if (!$self->debug) { #Otherwise we've already printed this, but we need to know if we encounter this
                warn "RAW CONTENT:";
                warn $response->content
            }
            return 0;
        }
    }
}

=head1 USER METHODS

=head2 B<getUsers ()>

Get all the user definitions for the provided Test Rail install.
Returns ARRAYREF of user definition HASHREFs.

=cut

sub getUsers {
    my $self = shift;
    $self->{'user_cache'} = $self->_doRequest('index.php?/api/v2/get_users');
    return $self->{'user_cache'};
}

=head2 B<getUserByID(id)>
=cut
=head2 B<getUserByName(name)>
=cut
=head2 B<getUserByEmail(email)>

Get user definition hash by ID, Name or Email.
Returns user def HASHREF.

=cut


#I'm just using the cache for the following methods because it's more straightforward and faster past 1 call.
sub getUserByID {
    my ($self,$user) = @_;
    $self->getUsers() if (!scalar(@{$self->{'user_cache'}}));

    foreach my $usr (@{$self->{'user_cache'}}) {
        return $usr if $usr->{'id'} == $user;
    }
    return 0;
}

sub getUserByName {
    my ($self,$user) = @_;
    $self->getUsers() if (!scalar(@{$self->{'user_cache'}}));
    foreach my $usr (@{$self->{'user_cache'}}) {
        return $usr if $usr->{'name'} eq $user;
    }
    return 0;
}

sub getUserByEmail {
    my ($self,$user) = @_;
    $self->getUsers() if (!scalar(@{$self->{'user_cache'}}));
    foreach my $usr (@{$self->{'user_cache'}}) {
        return $usr if $usr->{'email'} eq $user;
    }
    return 0;
}

=head1 PROJECT METHODS

=head2 B<createProject (name, [description,send_announcement])>

Creates new Project (Database of testsuites/tests).
Optionally specify an announcement to go out to the users.
Requires TestRail admin login.

=over 4

=item STRING C<NAME> - Desired name of project.

=item STRING C<DESCRIPTION> (optional) - Description of project.  Default value is 'res ipsa loquiter'.

=item BOOLEAN C<SEND ANNOUNCEMENT> (optional) - Whether to confront users with an announcement about your awesome project on next login.  Default false.

=back

Returns project definition HASHREF on success, false otherwise.

    $tl->createProject('Widgetronic 4000', 'Tests for the whiz-bang new product', true);

=cut

sub createProject {
    my ($self,$name,$desc,$announce) = @_;
    $desc     //= 'res ipsa loquiter';
    $announce //= 0;

    my $input = {
        name              => $name,
        announcement      => $desc,
        show_announcement => $announce ? Types::Serialiser::true : Types::Serialiser::false
    };

    my $result = $self->_doRequest('index.php?/api/v2/add_project','POST',$input);
    return $result;

}

=head2 B<deleteProjectByID (id)>

Deletes specified project by ID.
Requires TestRail admin login.

=over 4

=item STRING C<NAME> - Desired name of project.

=back

Returns BOOLEAN.

    $success = $tl->deleteProject(1);

=cut

sub deleteProject {
    my ($self,$proj) = @_;
    my $result = $self->_doRequest('index.php?/api/v2/delete_project/'.$proj,'POST');
    return $result;
}

=head2 B<getProjects ()>

Get all available projects

Returns array of project definition HASHREFs, false otherwise.

    $projects = $tl->getProjects;

=cut

sub getProjects {
    my $self = shift;

    my $result = $self->_doRequest('index.php?/api/v2/get_projects');

    #Save state for future use, if needed
    if (!scalar(@{$self->{'testtree'}})) {
        $self->{'testtree'} = $result if $result;
    }

    if ($result) {
        #Note that it's a project for future reference by recursive tree search
        for my $pj (@{$result}) {
            $pj->{'type'} = 'project';
        }
    }

    return $result;
}

=head2 B<getProjectByName ($project)>

Gets some project definition hash by it's name

=over 4

=item STRING C<PROJECT> - desired project

=back

Returns desired project def HASHREF, false otherwise.

    $projects = $tl->getProjectByName('FunProject');

=cut

sub getProjectByName {
    my ($self,$project) = @_;
    confess "No project provided." unless $project;

    #See if we already have the project list...
    my $projects = $self->{'testtree'};
    $projects = $self->getProjects() unless scalar(@$projects);

    #Search project list for project
    for my $candidate (@$projects) {
        return $candidate if ($candidate->{'name'} eq $project);
    }

    return 0;
}

=head2 B<getProjectByID ($project)>

Gets some project definition hash by it's ID

=over 4

=item INTEGER C<PROJECT> - desired project

=back

Returns desired project def HASHREF, false otherwise.

    $projects = $tl->getProjectByID(222);

=cut

sub getProjectByID {
    my ($self,$project) = @_;
    confess "No project provided." unless $project;

    #See if we already have the project list...
    my $projects = $self->{'testtree'};
    $projects = $self->getProjects() unless scalar(@$projects);

    #Search project list for project
    for my $candidate (@$projects) {
        return $candidate if ($candidate->{'id'} eq $project);
    }

    return 0;
}
=head1 TESTSUITE METHODS

=head2 B<createTestSuite (project_id, name, [description])>

Creates new TestSuite (folder of tests) in the database of test specifications under given project id having given name and details.

=over 4

=item INTEGER C<PROJECT ID> - ID of project this test suite should be under.

=item STRING C<NAME> - Desired name of test suite.

=item STRING C<DESCRIPTION> (optional) - Description of test suite.  Default value is 'res ipsa loquiter'.

=back

Returns TS definition HASHREF on success, false otherwise.

    $tl->createTestSuite(1, 'broken tests', 'Tests that should be reviewed');

=cut

sub createTestSuite {
    my ($self,$project_id,$name,$details) = @_;
    $details ||= 'res ipsa loquiter';

    my $input = {
        name        => $name,
        description => $details
    };

    my $result = $self->_doRequest('index.php?/api/v2/add_suite/'.$project_id,'POST',$input);
    return $result;

}

=head2 B<deleteTestSuite (suite_id)>

Deletes specified testsuite.

=over 4

=item INTEGER C<SUITE ID> - ID of testsuite to delete.

=back

Returns BOOLEAN.

    $tl->deleteTestSuite(1);

=cut

sub deleteTestSuite {
    my ($self,$suite_id) = @_;

    my $result = $self->_doRequest('index.php?/api/v2/delete_suite/'.$suite_id,'POST');
    return $result;

}

=head2 B<getTestSuites (project_id)>

Gets the testsuites for a project

=over 4

=item STRING C<PROJECT ID> - desired project's ID

=back

Returns ARRAYREF of testsuite definition HASHREFs, 0 on error.

    $suites = $tl->getTestSuites(123);

=cut

sub getTestSuites {
    my ($self,$proj) = @_;
    return $self->_doRequest('index.php?/api/v2/get_suites/'.$proj);
}

=head2 B<getTestSuiteByName (project_id,testsuite_name)>

Gets the testsuite that matches the given name inside of given project.

=over 4

=item STRING C<PROJECT ID> - ID of project holding this testsuite

=item STRING C<TESTSUITE NAME> - desired parent testsuite name

=back

Returns desired testsuite definition HASHREF, false otherwise.

    $suites = $tl->getTestSuitesByName(321, 'hugSuite');

=cut

sub getTestSuiteByName {
    my ($self,$project_id,$testsuite_name) = @_;

    #TODO cache
    my $suites = $self->getTestSuites($project_id);
    return 0 if !$suites; #No suites for project, or no project

    foreach my $suite (@$suites) {
        return  $suite if $suite->{'name'} eq $testsuite_name;
    }
    return 0; #Couldn't find it
}

=head2 B<getTestSuiteByID (testsuite_id)>

Gets the testsuite with the given ID.

=over 4

=item STRING C<TESTSUITE_ID> - Testsuite ID.

=back

Returns desired testsuite definition HASHREF, false otherwise.

    $tests = $tl->getTestSuiteByID(123);

=cut

sub getTestSuiteByID {
    my ($self,$testsuite_id) = @_;

    my $result = $self->_doRequest('index.php?/api/v2/get_suite/'.$testsuite_id);
    return $result;
}

=head1 SECTION METHODS

=head2 B<createSection(project_id,suite_id,name,[parent_id])>

Creates a section.

=over 4

=item INTEGER C<PROJECT ID> - Parent Project ID.

=item INTEGER C<SUITE ID> - Parent Testsuite ID.

=item STRING C<NAME> - desired section name.

=item INTEGER C<PARENT ID> (optional) - parent section id

=back

Returns new section definition HASHREF, false otherwise.

    $section = $tr->createSection(1,1,'nugs',1);

=cut

sub createSection {
    my ($self,$project_id,$suite_id,$name,$parent_id) = @_;

    my $input = {
        name     => $name,
        suite_id => $suite_id
    };
    $input->{'parent_id'} = $parent_id if $parent_id;

    my $result = $self->_doRequest('index.php?/api/v2/add_section/'.$project_id,'POST',$input);
    return $result;

}

=head2 B<deleteSection (section_id)>

Deletes specified section.

=over 4

=item INTEGER C<SECTION ID> - ID of section to delete.

=back

Returns BOOLEAN.

    $tr->deleteSection(1);

=cut

sub deleteSection {
    my ($self,$section_id) = @_;

    my $result = $self->_doRequest('index.php?/api/v2/delete_section/'.$section_id,'POST');
    return $result;

}

=head2 B<getSections (project_id,suite_id)>

Gets sections for a given project and suite.

=over 4

=item INTEGER C<PROJECT ID> - ID of parent project.

=item INTEGER C<SUITE ID> - ID of suite to get sections for.

=back

Returns ARRAYREF of section definition HASHREFs.

    $tr->getSections(1,2);

=cut

sub getSections {
    my ($self,$project_id,$suite_id) = @_;
    return $self->_doRequest("index.php?/api/v2/get_sections/$project_id&suite_id=$suite_id");
}

=head2 B<getSectionByID (section_id)>

Gets desired section.

=over 4

=item INTEGER C<PROJECT ID> - ID of parent project.

=item INTEGER C<SUITE ID> - ID of suite to get sections for.

=back

Returns section definition HASHREF.

    $tr->getSectionByID(344);

=cut

sub getSectionByID {
    my ($self,$section_id) = @_;
    return $self->_doRequest("index.php?/api/v2/get_section/$section_id");
}

=head2 B<getSectionByName (project_id,suite_id,name)>

Gets desired section.

=over 4

=item INTEGER C<PROJECT ID> - ID of parent project.

=item INTEGER C<SUITE ID> - ID of suite to get section for.

=item STRING C<NAME> - name of section to get

=back

Returns section definition HASHREF.

    $tr->getSectionByName(1,2,'nugs');

=cut

sub getSectionByName {
    my ($self,$project_id,$suite_id,$section_name) = @_;
    my $sections = $self->getSections($project_id,$suite_id);
    foreach my $sec (@$sections) {
        return $sec if $sec->{'name'} eq $section_name;
    }
    return 0;
}

=head1 CASE METHODS

=head2 B<getCaseTypes ()>

Gets possible case types.

Returns ARRAYREF of case type definition HASHREFs.

    $tr->getCaseTypes();

=cut

sub getCaseTypes {
    my $self = shift;
    $self->{'type_cache'} = $self->_doRequest("index.php?/api/v2/get_case_types") if !$self->type_cache; #We can't change this with API, so assume it is static
    return $self->{'type_cache'};
}

=head2 B<getCaseTypeByName (name)>

Gets case type by name.

=over 4

=item STRING C<NAME> - Name of desired case type

=back

Returns case type definition HASHREF.

    $tr->getCaseTypeByName();

=cut

sub getCaseTypeByName {
    #Useful for marking automated tests, etc
    my ($self,$name) = @_;
    my $types = $self->getCaseTypes();
    foreach my $type (@$types) {
        return $type if $type->{'name'} eq $name;
    }
    return 0;
}

=head2 B<createCase(section_id,title,type_id,options,extra_options)>

Creates a test case.

=over 4

=item INTEGER C<SECTION ID> - Parent Project ID.

=item STRING C<TITLE> - Case title.

=item INTEGER C<TYPE_ID> - desired test type's ID.

=item HASHREF C<OPTIONS> (optional) - Custom fields in the case are the keys, set to the values provided.  See TestRail API documentation for more info.

=item HASHREF C<EXTRA OPTIONS> (optional) - contains priority_id, estimate, milestone_id and refs as possible keys.  See TestRail API documentation for more info.

=back

Returns new case definition HASHREF, false otherwise.

    $custom_opts = {
        preconds => "Test harness installed",
        steps         => "Do the needful",
        expected      => "cubicle environment transforms into Dali painting"
    };

    $other_opts = {
        priority_id => 4,
        milestone_id => 666,
        estimate    => '2m 45s',
        refs => ['TRACE-22','ON-166'] #ARRAYREF of bug IDs.
    }

    $case = $tr->createCase(1,'Do some stuff',3,$custom_opts,$other_opts);

=cut

sub createCase {
    my ($self,$section_id,$title,$type_id,$opts,$extras) = @_;

    my $stuff = {
        title   => $title,
        type_id => $type_id
    };

    #Handle sort of optional but baked in options
    if (defined($extras) && reftype($extras) eq 'HASH') {
        $stuff->{'priority_id'}  = $extras->{'priority_id'}       if defined($extras->{'priority_id'});
        $stuff->{'estimate'}     = $extras->{'estimate'}          if defined($extras->{'estimate'});
        $stuff->{'milestone_id'} = $extras->{'milestone_id'}      if defined($extras->{'milestone_id'});
        $stuff->{'refs'}         = join(',',@{$extras->{'refs'}}) if defined($extras->{'refs'});
    }

    #Handle custom fields
    if (defined($opts) && reftype($opts) eq 'HASH') {
        foreach my $key (keys(%$opts)) {
            $stuff->{"custom_$key"} = $opts->{$key};
        }
    }

    my $result = $self->_doRequest("index.php?/api/v2/add_case/$section_id",'POST',$stuff);
    return $result;
}

=head2 B<deleteCase (case_id)>

Deletes specified section.

=over 4

=item INTEGER C<CASE ID> - ID of case to delete.

=back

Returns BOOLEAN.

    $tr->deleteCase(1324);

=cut

sub deleteCase {
    my ($self,$case_id) = @_;
    my $result = $self->_doRequest("index.php?/api/v2/delete_case/$case_id",'POST');
    return $result;
}

=head2 B<getCases (project_id,suite_id,section_id)>

Gets cases for provided section.

=over 4

=item INTEGER C<PROJECT ID> - ID of parent project.

=item INTEGER C<SUITE ID> - ID of parent suite.

=item INTEGER C<SECTION ID> - ID of parent section

=back

Returns ARRAYREF of test case definition HASHREFs.

    $tr->getCases(1,2,3);

=cut

sub getCases {
    my ($self,$project_id,$suite_id,$section_id) = @_;
    my $url = "index.php?/api/v2/get_cases/$project_id&suite_id=$suite_id";
    $url .= "&section_id=$section_id" if $section_id;
    return $self->_doRequest($url);
}

=head2 B<getCaseByName (project_id,suite_id,section_id,name)>

Gets case by name.

=over 4

=item INTEGER C<PROJECT ID> - ID of parent project.

=item INTEGER C<SUITE ID> - ID of parent suite.

=item INTEGER C<SECTION ID> - ID of parent section.

=item STRING <NAME> - Name of desired test case.

=back

Returns test case definition HASHREF.

    $tr->getCaseByName(1,2,3,'nugs');

=cut

sub getCaseByName {
    my ($self,$project_id,$suite_id,$section_id,$name) = @_;
    my $cases = $self->getCases($project_id,$suite_id,$section_id);
    foreach my $case (@$cases) {
        return $case if $case->{'title'} eq $name;
    }
    return 0;
}

=head2 B<getCaseByID (case_id)>

Gets case by ID.

=over 4

=item INTEGER C<CASE ID> - ID of case.

=back

Returns test case definition HASHREF.

    $tr->getCaseByID(1345);

=cut

sub getCaseByID {
    my ($self,$case_id) = @_;
    return $self->_doRequest("index.php?/api/v2/get_case/$case_id");
}

=head1 RUN METHODS

=head2 B<createRun (project_id)>

Create a run.

=over 4

=item INTEGER C<PROJECT ID> - ID of parent project.

=item INTEGER C<SUITE ID> - ID of suite to base run on

=item STRING C<NAME> - Name of run

=item STRING C<DESCRIPTION> (optional) - Description of run

=item INTEGER C<MILESTONE_ID> (optional) - ID of milestone

=item INTEGER C<ASSIGNED_TO_ID> (optional) - User to assign the run to

=item ARRAYREF C<CASE IDS> (optional) - Array of case IDs in case you don't want to use the whole testsuite when making the build.

=back

Returns run definition HASHREF.

    $tr->createRun(1,1345,'RUN AWAY','SO FAR AWAY',22,3,[3,4,5,6]);

=cut

#If you pass an array of case ids, it implies include_all is false
sub createRun {
    my ($self,$project_id,$suite_id,$name,$desc,$milestone_id,$assignedto_id,$case_ids) = @_;

    my $stuff = {
        suite_id      => $suite_id,
        name          => $name,
        description   => $desc,
        milestone_id  => $milestone_id,
        assignedto_id => $assignedto_id,
        include_all   => $case_ids ? Types::Serialiser::false : Types::Serialiser::true,
        case_ids      => $case_ids
    };

    my $result = $self->_doRequest("index.php?/api/v2/add_run/$project_id",'POST',$stuff);
    return $result;
}

=head2 B<deleteRun (run_id)>

Deletes specified run.

=over 4

=item INTEGER C<RUN ID> - ID of run to delete.

=back

Returns BOOLEAN.

    $tr->deleteRun(1324);

=cut

sub deleteRun {
    my ($self,$suite_id) = @_;
    my $result = $self->_doRequest("index.php?/api/v2/delete_run/$suite_id",'POST');
    return $result;
}

=head2 B<getRunByName (project_id,name)>

Gets run by name.

=over 4

=item INTEGER C<PROJECT ID> - ID of parent project.

=item STRING <NAME> - Name of desired run.

=back

Returns run definition HASHREF.

    $tr->getRunByName(1,'gravy');

=cut

sub getRuns {
    my ($self,$project_id) = @_;
    return $self->_doRequest("index.php?/api/v2/get_runs/$project_id");
}

sub getRunByName {
    my ($self,$project_id,$name) = @_;
    my $runs = $self->getRuns($project_id);
    foreach my $run (@$runs) {
        return $run if $run->{'name'} eq $name;
    }
    return 0;
}

=head2 B<getRunByID (run_id)>

Gets run by ID.

=over 4

=item INTEGER C<RUN ID> - ID of desired run.

=back

Returns run definition HASHREF.

    $tr->getRunByID(7779311);

=cut

sub getRunByID {
    my ($self,$run_id) = @_;
    return $self->_doRequest("index.php?/api/v2/get_run/$run_id");
}

=head1 PLAN METHODS

=head2 B<createRun (project_id,name,description,milestone_id,entries)>

Create a run.

=over 4

=item INTEGER C<PROJECT ID> - ID of parent project.

=item STRING C<NAME> - Name of plan

=item STRING C<DESCRIPTION> (optional) - Description of plan

=item INTEGER C<MILESTONE_ID> (optional) - ID of milestone

=item ARRAYREF C<ENTRIES> (optional) - New Runs to initially populate the plan with -- See TestLink API documentation for more advanced inputs here.

=back

Returns test plan definition HASHREF, or false on failure.

    $entries = {
        suite_id => 345,
        include_all => Types::Serialiser::true,
        assignedto_id => 1
    }

    $tr->createPlan(1,'Gosplan','Robo-Signed Soviet 5-year plan',22,$entries);

=cut

sub createPlan {
    my ($self,$project_id,$name,$desc,$milestone_id,$entries) = @_;

    my $stuff = {
        name          => $name,
        description   => $desc,
        milestone_id  => $milestone_id,
        entries       => $entries
    };

    my $result = $self->_doRequest("index.php?/api/v2/add_plan/$project_id",'POST',$stuff);
    return $result;
}

=head2 B<deletePlan (plan_id)>

Deletes specified plan.

=over 4

=item INTEGER C<PLAN ID> - ID of plan to delete.

=back

Returns BOOLEAN.

    $tr->deletePlan(8675309);

=cut

sub deletePlan {
    my ($self,$plan_id) = @_;
    my $result = $self->_doRequest("index.php?/api/v2/delete_plan/$plan_id",'POST');
    return $result;
}

=head2 B<getPlans (project_id)>

Deletes specified plan.

=over 4

=item INTEGER C<PROJECT ID> - ID of parent project.

=back

Returns ARRAYREF of plan definition HASHREFs.

    $tr->getPlans(8);

=cut

sub getPlans {
    my ($self,$project_id) = @_;
    return $self->_doRequest("index.php?/api/v2/get_plans/$project_id");
}

=head2 B<getPlanByName (project_id,name)>

Gets specified plan by name.

=over 4

=item INTEGER C<PROJECT ID> - ID of parent project.

=item STRING C<NAME> - Name of test plan.

=back

Returns plan definition HASHREF.

    $tr->getPlanByName(8,'GosPlan');

=cut

sub getPlanByName {
    my ($self,$project_id,$name) = @_;
    my $plans = $self->getPlans($project_id);
    foreach my $plan (@$plans) {
        return $plan if $plan->{'name'} eq $name;
    }
    return 0;
}

=head2 B<getPlanByID (plan_id)>

Gets specified plan by ID.

=over 4

=item INTEGER C<PLAN ID> - ID of plan.

=back

Returns plan definition HASHREF.

    $tr->getPlanByID(2);

=cut

sub getPlanByID {
    my ($self,$plan_id) = @_;
    return $self->_doRequest("index.php?/api/v2/get_plan/$plan_id");
}

=head1 MILESTONE METHODS

=head2 B<createMilestone (project_id,name,description,due_on)>

Create a milestone.

=over 4

=item INTEGER C<PROJECT ID> - ID of parent project.

=item STRING C<NAME> - Name of milestone

=item STRING C<DESCRIPTION> (optional) - Description of milestone

=item INTEGER C<DUE_ON> - Date at which milestone should be completed. Unix Timestamp.

=back

Returns milestone definition HASHREF, or false on failure.

    $tr->createMilestone(1,'Patriotic victory of world perlism','Accomplish by Robo-Signed Soviet 5-year plan',time()+157788000);

=cut

sub createMilestone {
    my ($self,$project_id,$name,$desc,$due_on) = @_;

    my $stuff = {
        name        => $name,
        description => $desc,
        due_on      => $due_on # unix timestamp
    };

    my $result = $self->_doRequest("index.php?/api/v2/add_milestone/$project_id",'POST',$stuff);
    return $result;
}

=head2 B<deleteMilestone (milestone_id)>

Deletes specified milestone.

=over 4

=item INTEGER C<MILESTONE ID> - ID of milestone to delete.

=back

Returns BOOLEAN.

    $tr->deleteMilestone(86);

=cut

sub deleteMilestone {
    my ($self,$milestone_id) = @_;
    my $result = $self->_doRequest("index.php?/api/v2/delete_milestone/$milestone_id",'POST');
    return $result;
}

=head2 B<getMilestones (project_id)>

Get milestones for some project.

=over 4

=item INTEGER C<PROJECT ID> - ID of parent project.

=back

Returns ARRAYREF of milestone definition HASHREFs.

    $tr->getMilestones(8);

=cut

sub getMilestones {
    my ($self,$project_id) = @_;
    return $self->_doRequest("index.php?/api/v2/get_milestones/$project_id");
}

=head2 B<getMilestoneByName (project_id,name)>

Gets specified milestone by name.

=over 4

=item INTEGER C<PROJECT ID> - ID of parent project.

=item STRING C<NAME> - Name of milestone.

=back

Returns milestone definition HASHREF.

    $tr->getMilestoneByName(8,'whee');

=cut

sub getMilestoneByName {
    my ($self,$project_id,$name) = @_;
    my $milestones = $self->getMilestones($project_id);
    foreach my $milestone (@$milestones) {
        return $milestone if $milestone->{'name'} eq $name;
    }
    return 0;
}

=head2 B<getMilestoneByID (plan_id)>

Gets specified milestone by ID.

=over 4

=item INTEGER C<MILESTONE ID> - ID of milestone.

=back

Returns milestione definition HASHREF.

    $tr->getMilestoneByID(2);

=cut

sub getMilestoneByID {
    my ($self,$milestone_id) = @_;
    return $self->_doRequest("index.php?/api/v2/get_milestone/$milestone_id");
}

=head1 TEST METHODS

=head2 B<getTests (run_id)>

Get tests for some run.

=over 4

=item INTEGER C<RUN ID> - ID of parent run.

=back

Returns ARRAYREF of test definition HASHREFs.

    $tr->getTests(8);

=cut

sub getTests {
    my ($self,$run_id) = @_;
    return $self->_doRequest("index.php?/api/v2/get_tests/$run_id");
}

=head2 B<getTestByName (run_id,name)>

Gets specified test by name.

=over 4

=item INTEGER C<RUN ID> - ID of parent run.

=item STRING C<NAME> - Name of milestone.

=back

Returns test definition HASHREF.

    $tr->getTestByName(36,'wheeTest');

=cut

sub getTestByName {
    my ($self,$run_id,$name) = @_;
    my $tests = $self->getTests($run_id);
    foreach my $test (@$tests) {
        return $test if $test->{'title'} eq $name;
    }
    return 0;
}

=head2 B<getTestByID (test_id)>

Gets specified test by ID.

=over 4

=item INTEGER C<TEST ID> - ID of test.

=back

Returns test definition HASHREF.

    $tr->getTestByID(222222);

=cut

sub getTestByID {
    my ($self,$test_id) = @_;
    return $self->_doRequest("index.php?/api/v2/get_test/$test_id");
}

=head2 B<getTestResultFields()>

Gets custom fields that can be set for tests.

Returns ARRAYREF of result definition HASHREFs.

=cut

sub getTestResultFields {
    my $self = shift;
    return $self->_doRequest('index.php?/api/v2/get_result_fields');
}

=head2 B<getPossibleTestStatuses()>

Gets all possible statuses a test can be set to.

Returns ARRAYREF of status definition HASHREFs.

=cut

sub getPossibleTestStatuses {
    my $self = shift;
    return $self->_doRequest('index.php?/api/v2/get_statuses');
}

=head2 B<createTestResults(test_id,status_id,comment,options,custom_options)>

Creates a result entry for a test.

Returns result definition HASHREF.

    $options = {
        elapsed => '30m 22s',
        defects => ['TSR-3','BOOM-44'],
        version => '6969'
    };

    $custom_options = {
        step_results => [
            {
                content   => 'Step 1',
                expected  => "Bought Groceries",
                actual    => "No Dinero!",
                status_id => 2
            },
            {
                content   => 'Step 2',
                expected  => 'Ate Dinner',
                actual    => 'Went Hungry',
                status_id => 2
            }
        ]
    };

    $res = $tr->createTestResults(1,2,'Test failed because it was all like WAAAAAAA when I poked it',$options,$custom_options);

=cut

sub createTestResults {
    my ($self,$test_id,$status_id,$comment,$opts,$custom_fields) = @_;
    my $stuff = {
        status_id     => $status_id,
        comment       => $comment
    };

    #Handle options
    if (defined($opts) && reftype($opts) eq 'HASH') {
        $stuff->{'version'}       = defined($opts->{'version'}) ? $opts->{'version'} : undef;
        $stuff->{'elapsed'}       = defined($opts->{'elapsed'}) ? $opts->{'elapsed'} : undef;
        $stuff->{'defects'}       = defined($opts->{'defects'}) ? join(',',@{$opts->{'defects'}}) : undef;
        $stuff->{'assignedto_id'} = defined($opts->{'assignedto_id'}) ? $opts->{'assignedto_id'} : undef;
    }

    #Handle custom fields
    if (defined($custom_fields) && reftype($custom_fields) eq 'HASH') {
        foreach my $field (keys(%$custom_fields)) {
            $stuff->{"custom_$field"} = $custom_fields->{$field};
        }
    }

    return $self->_doRequest("index.php?/api/v2/add_result/$test_id",'POST',$stuff);
}

=head2 B<getTestResults(test_id,limit)>

Get the recorded results for desired test, limiting output to 'limit' entries.

=over 4

=item INTEGER C<TEST_ID> - ID of desired test

=item POSITIVE INTEGER C<LIMIT> - provide no more than this number of results.

=back

Returns ARRAYREF of result definition HASHREFs.

=cut

sub getTestResults {
    my ($self,$test_id,$limit) = @_;
    my $url = "index.php?/api/v2/get_results/$test_id";
    $url .= "&limit=$limit" if defined($limit);
    return $self->_doRequest($url);
}

=head2 B<buildStepResults(content,expected,actual,status_id)>

Convenience method to build the stepResult hashes seen in the custom options for getTestResults.

=cut

#Convenience method for building stepResults
sub buildStepResults {
    my ($content,$expected,$actual,$status_id) = @_;
    return {
        content   => $content,
        expected  => $expected,
        actual    => $actual,
        status_id => $status_id
    };
}

1;

__END__

=head1 SEE ALSO

L<Test::More>

L<HTTP::Request>

L<LWP::UserAgent>

L<JSON::XS>

http://docs.gurock.com/testrail-api2/start

=head1 AUTHOR

George Baugh <teodesian@cpan.org>

=head1 SPECIAL THANKS

Thanks to cPanel Inc, for graciously funding the creation of this module.

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2014 by George S. Baugh.

This is free software; you can redistribute it and/or modify it under the same terms as the Perl 5 programming language system itself.
