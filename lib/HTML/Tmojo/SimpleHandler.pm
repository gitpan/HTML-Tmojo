###########################################################################
# Copyright 2004 Lab-01 LLC <http://lab-01.com/>
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#    http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Tmojo(tm) is a trademark of Lab-01 LLC.
###########################################################################

package HTML::Tmojo::SimpleHandler;

use strict;

use Apache::Constants qw(OK);

use HTML::Tmojo;
use HTML::Tmojo::HttpArgParser;

sub handler {
	my $apache_request = shift;
	
	# PRIME OUR COOL OBJECTS
	my $arg_parser = HTML::Tmojo::HttpArgParser->new();
	my $tmojo = HTML::Tmojo->new();
	
	# DECIDE ON THE DEFAULT CONTAINER
	my $default_container = $ENV{TMOJO_DEFAULT_CONTAINER};
	
	# GET THE ARGUMENTS
	my %args = $arg_parser->args();
	
	# GET THE TMOJO TEMPLATE PATH
	my $template_id = $ENV{PATH_INFO};
	
	# OUTPUT THE APACHE HEADER
	$apache_request->send_http_header('text/html; charset=utf8');
	
	# CALL THE TMOJO TEMPLATE
	if ($default_container ne '') {
		print $tmojo->call_with_container($template_id, $default_container, %args);
	} else {
		print $tmojo->call($template_id, %args);
	}
	
	# AND WE'RE DONE
	return OK;
}

1;
