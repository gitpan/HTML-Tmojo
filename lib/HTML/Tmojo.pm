###########################################################################
# Copyright 2003, 2004 Lab-01 LLC <http://lab-01.com/>
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

package HTML::Tmojo;

our $VERSION = '0.262';

=head1 NAME

HTML::Tmojo - Dynamic Text Generation Engine

=head1 SYNOPSIS

  my $tmojo = HTML::Tmojo->new(
    template_dir => '/location/of/templates',
    cache_dir    => '/place/to/save/compiled/templates',
  );
  
  my $result = $tmojo->call('my_template.tmojo', arg1 => 1, arg2 => 3);
  
  # HONESTLY, THIS SYNOPSIS DOESN'T COVER NEARLY ENOUGH.
  # GO READ TMOJO IN A NUTSHELL

=head1 ABSTRACT

  Tmojo is used for generating dynamic text documents.
  While it is particularly suited to generating HTML
  and XML documents, it can be used effectively to
  produce any text output, including dynamically
  generated source code.

=head1 AUTHOR

Will Conant <will@willconant.com>

=cut

use strict;
use Data::Dumper;
use Symbol qw(delete_package);

use HTML::Tmojo::TemplateLoader;

our %memory_cache;

sub new {
	my ($class, %args) = @_;

	if (defined $args{template_dir}) {
		$args{template_loader} = HTML::Tmojo::TemplateLoader->new($args{template_dir}, $args{tmojo_lite});
		delete $args{template_dir};
	}
	elsif (not defined $args{template_loader}) {
		$args{template_loader} = HTML::Tmojo::TemplateLoader->new($ENV{TMOJO_TEMPLATE_DIR}, $args{tmojo_lite});
	}
	
	%args = (
		cache_dir    => $ENV{TMOJO_CACHE_DIR},
		context_path => '',
		
		%args,
	);
	
	$args{cache_dir} =~ s/\/$//;
		
	my $self = {
		%args
	};
	
	return bless $self, $class;
}

sub call {
	my ($self, $template_id, %args) = @_;
	return $self->call_with_container($template_id, undef, %args);
}

sub call_with_container {
	my ($self, $template_id, $container_override_id, %args) = @_;
	
	my $result = eval {
	
		my $current_package = $self->get_template_class($template_id);
		my $current_template = $current_package->new(\%args);
		
		# WE HAVE TO KEEP TRACK OF WHICH CONTAINERS HAVE BEEN USED,
		# SO THAT USERS CAN'T CREATE AN INFINITE CONTAINER LOOP
		my %used_containers = (
			$self->normalize_template_id($template_id) => 1,
		);
		
		for (;;) {
			no strict 'refs';
			
			my $contextual_tmojo = ${$current_package . '::Tmojo'};
			
			my $container_id;
			if (defined $container_override_id) {
				$container_id = $container_override_id;
				$container_override_id = undef;
			}
			else {
				$container_id = ${$current_package . '::TMOJO_CONTAINER'};
			}
			
			if ($container_id ne '') {
				# NORMALIZE THE CONTAINER ID FOR GOOD MEASURE
				$container_id = $contextual_tmojo->normalize_template_id($container_id);
				
				# CHECK TO MAKE SURE THAT THE CONTAINER HASN'T ALREADY BEEN USED
				if ($used_containers{$container_id} == 1) {
					die "circular container reference, $container_id already used (this will cause an infinite loop)";
				}
				
				# PUT IT IN THE USED LIST
				$used_containers{$container_id} = 1;
				
				# MOVE ON UP
				$current_package = $contextual_tmojo->get_template_class($container_id);
				$current_template = $current_package->new(\%args, $current_template);
			}
			else {
				return $current_template->main();
			}
		}
	
	};
	if ($@) {
		$self->report_error($@);
	}
	
	return $result;
}

sub prepare {
	my ($self, $template_id, %args) = @_;
	
	my $package = $self->get_template_class($template_id);
	my $template = $package->new(\%args);
	
	return $template;
}

sub template_exists {
	my ($self, $template_id) = @_;
	
	$template_id = $self->normalize_template_id($template_id);
	return $self->{template_loader}->template_exists($template_id);	
}

sub report_error {
	my ($self, $error) = @_;
		
	my $err = (split(/\n/, $error))[0];
	if ($err =~ /at ([^\s]+) line\s+(\d+)/) {
		my $file_name = $1;
		my $line_number = $2;
		
		my $template_id;
		
		open FH, "$file_name.lines";
		local $/ = "\n"; # THIS CAN GET EXTRA SCREWED UP IN MOD_PERL
		
		my $cur_line = 1;
		while (my $line = <FH>) {
			if ($line =~ /^###TMOJO_TEMPLATE_ID: (.+)$/) {
				$template_id = $1;
				chomp $template_id;
			}
			
			if ($cur_line == $line_number) {
				if ($line =~ /###TMOJO_LINE: (\d+)$/) {
					die "Error at $template_id line $1.\n$@";
				}
			}
			
			$cur_line += 1;
		}
		close FH;
	}
	
	die $error;
}

sub compile_template {
	my ($source_lines, $template_id, $package_name) = @_;
	
	# NOW WE TURN THE TEMPLATE SRC INTO PERL ;)
	
	# FIRST, WE BREAK IT UP INTO SECTIONS
	my %sections;
	my $cur_section = 'sub:main';
	my $line_number = 0;
	
	my $perl_section = 0;
	my $perl_terminator;
	my $escape_section = 0;
	my $escape_terminator;
	
	foreach my $line (@$source_lines) {
		$line_number += 1;
		
		if ($perl_section == 1) {
			if ($line =~ /^\s*<\/:perl$perl_terminator>\s*$/) {
				$perl_section = 0;
				$perl_terminator = undef;
			}
			
			$sections{$cur_section} .= "$line_number:$line";
		}
		elsif ($escape_section == 1) {
			if ($line =~ /^\s*<\/:escape$escape_terminator>\s*$/) {
				$escape_section = 0;
				$escape_terminator = undef;
			}
			
			$sections{$cur_section} .= "$line_number:$line";
		}
		else {
			if ($cur_section =~ /^sub:/ and $line =~ /^\s*<:perl(-.+)?>\s*$/) {
				$perl_section = 1;
				$perl_terminator = $1;
				$sections{$cur_section} .= "$line_number:$line";
			}
			elsif ($cur_section =~ /^sub:/ and $line =~ /^\s*<:escape(-.+)?>\s*$/) {
				$escape_section = 1;
				$escape_terminator = $1;
				$sections{$cur_section} .= "$line_number:$line";
			}
			elsif ($line =~ /^\s*<:(global|init)>\s*$/) {
				$cur_section = $1;
			}
			elsif ($line =~ /^\s*<\/:(global|init)>\s*$/) {
				if ($cur_section ne $1) {
					die "didn't expect </:$1> on line $line_number";
				}
				else {
					$cur_section = 'sub:main';
				}
			}
			elsif ($line =~ /^\s*<:(?:sub|method)\s+(\w+)>\s*$/) {
				if ($1 eq 'main') {
					die "illegal method name 'main' on line $line_number";
				}
				if (defined $sections{"sub:$1"}) {
					die "attempting to redefine method $1";
				}
				
				$cur_section = "sub:$1";
			}
			elsif ($line =~ /^\s*<\/:(sub|method)>\s*$/) {
				if ($cur_section !~ /^sub:/) {
					die "didn't expect </:$1> on line $line_number";
				}
				else {
					$cur_section = 'sub:main';
				}
			}
			elsif ($line =~ /^\s*<\/:perl(-.+)?>\s*$/) {
				die "unexpected </:perl>";
			}
			elsif ($line =~ /^\s*<\/:escape(-.+)?>\s*$/) {
				die "unexpected </:escape>";
			}
			else {
				if ($cur_section eq 'global' or $cur_section eq 'init') {
					chomp $line;
					$sections{$cur_section} .= "$line###TMOJO_LINE: $line_number\n";
				}
				else {
					$sections{$cur_section} .= "$line_number:$line";
				}
			}
		}
	}
	
	if ($cur_section eq 'init') {
		die "missing </:init>";
	}
	elsif ($cur_section eq 'global') {
		die "missing </:global>";
	}
	elsif ($cur_section ne 'sub:main') {
		die "missing </:method>";
	}
	
	# PARSE EACH SECTION IN ORDER
	my $template_compiled = qq{###TMOJO_TEMPLATE_ID: $template_id
package $package_name;

use strict;

our \$Tmojo;

$sections{global}

sub new {					
my \$Self = {
	args    => \$_[1],
	next    => \$_[2],
	vars    => {},
};

bless \$Self, \$_[0];

# DEFINE THE IMPLICIT VARIABLES
my \$Next  = \$Self->{next};
our \%Args; local \*Args = \$Self->{args};
our \%Vars; local \*Vars = \$Self->{vars};

# --- BEGIN USER CODE ---
$sections{init}
# --- END USER CODE ---

# RETURN THE VALUE
return \$Self;
}
	};
			
	foreach my $section (keys %sections) {
		if ($section =~ /^sub:(\w+)$/) {
			
			my $sub_name = $1;
							
			# SPLIT INTO LINES
			my @lines = split /\n/, $sections{$section};
			
			# GET RID OF ANY TRAILING LINES THAT ARE ALL WHITESPACE
			while ($lines[-1] =~ /^\d+:\s*$/) {
				pop @lines;
			}
			
			my $section_src;
			my $stripped_beginning = 0;
			my $perl_section = 0;
			my $perl_terminator;
			my $escape_section = 0;
			my $escape_terminator;
			my @capture_stack;
			my @capture_lines;
			my @filter_stack;
			my @filter_lines;
			
			while (my $line = shift @lines) {
				$line =~ s/^(\d+)://;
				my $line_number = $1;
				
				if (@lines) {
					$line .= "\n";
				}
				
				if ($perl_section == 1) {
					if ($line =~ /^\s*<\/:perl$perl_terminator>\s*$/) {
						$perl_section = 0;
						$perl_terminator = undef;
						$section_src .= "\t# --- END USER <:perl> SECTION ---\n";
					}
					else {
						chomp $line;
						$section_src .= "$line###TMOJO_LINE: $line_number\n";
					}
				}
				elsif ($escape_section == 1) {
					if ($line =~ /^\s*<\/:escape$escape_terminator>\s*$/) {
						$escape_section = 0;
						$escape_terminator = undef;
						$section_src .= "\t# --- END USER <:escape> SECTION ---\n";
					}
					else {
						my $dumper = Data::Dumper->new([$line]);
						$dumper->Useqq(1);
						$dumper->Indent(0);
						$dumper->Terse(1);
						my $literal = $dumper->Dump();
						$section_src .= "\t\$Result .= $literal;###TMOJO_LINE: $line_number\n";
					}
				}
				else {
					if ($line =~ /^\s*<:perl(-.+)?>\s*$/) {
						$perl_section = 1;
						$perl_terminator = $1;
						$section_src .= "\t# --- BEGIN USER <:perl> SECTION ---\n";
					}
					elsif ($line =~ /^\s*<:escape(-.+)?>\s*$/) {
						$escape_section = 1;
						$escape_terminator = $1;
						$section_src .= "\t# --- BEGIN USER <:escape> SECTION ---\n";
					}
					elsif ($line =~ /^\s*<:capture\s+(.+)>\s*$/) {
						push @capture_stack, $1;
						push @capture_lines, $line_number;
						$section_src .= "\tpush(\@ResultStack, ''); local \*Result = \\\$ResultStack[-1];\n";
					}
					elsif ($line =~ /^\s*<\/:capture>\s*$/) {
						if (not @capture_stack) {
							die "unexpected </:capture>";
						}
						
						my $capture_lvalue = pop @capture_stack;
						my $capture_line = pop @capture_lines;
						$section_src .= "\t$capture_lvalue = pop(\@ResultStack); local \*Result = \\\$ResultStack[-1];###TMOJO_LINE: $capture_line\n";
					}
					elsif ($line =~ /^\s*<:filter\s+(.+)>\s*$/) {
						push @filter_stack, $1;
						push @filter_lines, $line_number;
						$section_src .= "\tpush(\@ResultStack, ''); local \*Result = \\\$ResultStack[-1];\n";
					}
					elsif ($line =~ /^\s*<\/:filter>\s*$/) {
						if (not @filter_stack) {
							die "unexpected </:filter>";
						}
						
						my $filter_code = pop @filter_stack;
						my $filter_line = pop @filter_lines;
						$section_src .= "\t\$ResultStack[-2] .= ($filter_code); pop(\@ResultStack); local \*Result = \\\$ResultStack[-1];###TMOJO_LINE: $filter_line\n";
					}
					elsif ($line =~ /^(\s*): ?(.+)/) {
						$section_src .= "$1$2###TMOJO_LINE: $line_number\n";
					}
					else {
						unless ($stripped_beginning) {
							$line =~ s/^\s+//;
						}
					
						while ($line) {
							$stripped_beginning = 1;
						
							if ($line =~ s/^(.*?)<://) {
								my $dumper = Data::Dumper->new([$1]);
								$dumper->Useqq(1);
								$dumper->Indent(0);
								$dumper->Terse(1);
								my $literal = $dumper->Dump();
								$section_src .= "\t\$Result .= $literal;###TMOJO_LINE: $line_number\n";
								
								if ($line =~ s/^(.*?):>//) {
									$section_src .= "\t\$Result .= ($1);###TMOJO_LINE: $line_number\n";
								}
								else {
									die "missing :> in $template_id on line $line_number";
								}
							}
							else {
								my $dumper = Data::Dumper->new([$line]);
								$dumper->Useqq(1);
								$dumper->Indent(0);
								$dumper->Terse(1);
								my $literal = $dumper->Dump();
								$section_src .= "\t\$Result .= $literal;###TMOJO_LINE: $line_number\n";
								
								$line = '';
							}
						}
					}
				}
			}
			
			# MAKE SURE WE DON'T HAVE ANY RUN-AWAY SECTIONS
			if ($perl_section == 1) {
				die "missing </:perl$perl_terminator>";
			}
			
			if ($escape_section == 1) {
				die "missing </:escape$escape_terminator>";
			}
			
			if (@capture_stack) {
				die "missing </:capture>";
			}
			
			if (@filter_stack) {
				die "missing </:filter>";
			}
			
			# ADD THE FUNCTION TO THE PACKAGE
			$template_compiled .= qq{
sub $sub_name {
my \$Self = shift \@_;

# DEFINE THE IMPLICIT VARIABLES
my \$Next  = \$Self->{next};
our \%Args; local \*Args = \$Self->{args};
our \%Vars; local \*Vars = \$Self->{vars};

my \@ResultStack = ('');
our \$Result; local \*Result = \\\$ResultStack[-1];


# --- BEGIN USER CODE ---
$section_src
# --- END USER CODE ---

return \$Result;
}
			};
		}
	}
	
	# AND THE END
	$template_compiled .= "\n1;\n";
	
	return $template_compiled;
}

sub compile_lite_template {
	my ($source_lines, $template_id, $package_name) = @_;
	
	# NOW WE TURN THE TEMPLATE SRC INTO PERL ;)
	
	# FIRST, WE BREAK IT UP INTO SECTIONS
	my %sections;
	my $cur_section = 'main';
	my $line_number = 0;
		
	foreach my $line (@$source_lines) {
		$line_number += 1;
		
		if ($line =~ /^\s*<:(\w+)>\s*$/) {
			if ($1 eq 'main') {
				die "illegal section name 'main' on line $line_number";
			}
			if (defined $sections{$1}) {
				die "attempting to redefine section $1";
			}
			
			$cur_section = $1;
		}
		elsif ($line =~ /^\s*<\/:(\w+)>\s*$/) {
			if ($cur_section ne $1) {
				die "expected </:$cur_section>";
			}
			
			$cur_section = 'main';
		}
		else {
			$sections{$cur_section} .= "$line_number:$line";
		}
		
	}
	
	if ($cur_section ne 'main') {
		die "missing </:$cur_section>";
	}
	
	# PARSE EACH SECTION IN ORDER
	my $template_compiled = qq{###TMOJO_TEMPLATE_ID: $template_id
package $package_name;

use strict;

our \$Tmojo;

sub new {					
	my \$Self = {
		args    => \$_[1],
	};
	
	# RETURN THE VALUE
	return bless \$Self, \$_[0];
}
	};
			
	foreach my $section (keys %sections) {
						
		# SPLIT INTO LINES
		my @lines = split /\n/, $sections{$section};
		
		# GET RID OF ANY TRAILING LINES THAT ARE ALL WHITESPACE
		while ($lines[-1] =~ /^\d+:\s*$/) {
			pop @lines;
		}
		
		my $section_src;
		my $stripped_beginning = 0;
		
		while (my $line = shift @lines) {
			$line =~ s/^(\d+)://;
			my $line_number = $1;
			
			if (@lines) {
				$line .= "\n";
			}
			
			unless ($stripped_beginning) {
				$line =~ s/^\s+//;
			}
		
			while ($line) {
				$stripped_beginning = 1;
			
				if ($line =~ s/^(.*?)<://) {
					my $dumper = Data::Dumper->new([$1]);
					$dumper->Useqq(1);
					$dumper->Indent(0);
					$dumper->Terse(1);
					my $literal = $dumper->Dump();
					$section_src .= "\t\$Result .= $literal;###TMOJO_LINE: $line_number\n";
					
					if ($line =~ s/^\s*\$(\w+)\s*:>//) {
						$section_src .= "\t\$Result .= \$args->{$1};###TMOJO_LINE: $line_number\n";
					}
					else {
						die "malformed merge tag in $template_id on line $line_number";
					}
				}
				else {
					my $dumper = Data::Dumper->new([$line]);
					$dumper->Useqq(1);
					$dumper->Indent(0);
					$dumper->Terse(1);
					my $literal = $dumper->Dump();
					$section_src .= "\t\$Result .= $literal;###TMOJO_LINE: $line_number\n";
					
					$line = '';
				}
			}
		}
		
		# ADD THE FUNCTION TO THE PACKAGE
		$template_compiled .= qq{
sub $section {
	my \$Self = shift \@_;
	
	my \$args = \$Self->{args};
	if (\@_) {
		\$args = { \@_ };
	}
	
	my \$Result = '';
	
	# --- BEGIN USER CODE ---
	$section_src
	# --- END USER CODE ---
	
	return \$Result;
}
		};
	}
	
	# AND THE END
	$template_compiled .= "\n1;\n";
	
	return $template_compiled;
}

sub get_template_class {

	my ($self, $template_id, $used_parents) = @_;
	
	# NORMALIZE THE TEMPLATE_ID
	my $normalized_template_id = $self->normalize_template_id($template_id);
	
	# GET THE PACKAGE NAME
	my $package_name = $self->{template_loader}->template_package_name($normalized_template_id);
	
	# FIGURE OUT WHERE WE'D CACHE THIS THING
	my $template_compiled_fn = $self->get_template_compiled_fn($package_name);
	
	# LOOK IN OUR CACHE TO SEE IF WE HAVE THE TEMPLATE
	my $cache_time_stamp = 0;
	if (-r $template_compiled_fn) {
		$cache_time_stamp = (stat($template_compiled_fn))[9];
	}
	
	# ATTEMPT TO LOAD THE TEMPLATE
	my ($template_lines, $tmojo_lite) = $self->{template_loader}->load_template($normalized_template_id, $cache_time_stamp);
	
	# IF $template_lines CAME BACK AS A ZERO, THEN OUR CACHED VERSION IS STILL GOOD
	my $cache_level = 0;
	if ($template_lines == 0) {
		$cache_level = 1;
		
		if (exists $memory_cache{$package_name}) {
			if ($cache_time_stamp <= $memory_cache{$package_name}) {
				$cache_level = 2;
			}
		}
	}
	
	# IF WE DON'T HAVE IT IN THE CACHE
	if ($cache_level == 0) {
			
		# COMPILE THE TEMPLATE
		my $template_compiled;
		if ($tmojo_lite) {
			$template_compiled = compile_lite_template($template_lines, $normalized_template_id, $package_name);
		}
		else {
			$template_compiled = compile_template($template_lines, $normalized_template_id, $package_name);
		}
		
		# CACHE THE TEMPLATE
		# ------------------
		# IT TURNS OUT THAT YOU CAN'T GET AWAY WITH HAVING THE LINE
		# NUMBERS IN THE PERL CODE, BECAUSE IT SCREWS UP qq{} AND
		# OTHER NEATO THINGS
		
		# SO, ALAS, NOW THAT WE'VE GONE TO THE TROUBLE OF ADDING THE
		# LINE NUMBERS, WE'RE GOING TO STRIP THEM AND PUT THEM IN
		# ANOTHER FILE... :(
		my @final_lines = split /\n/, $template_compiled;
		
		open CODE_FH, ">$template_compiled_fn" or die "$! ($template_compiled_fn)";
		open LINE_FH, ">$template_compiled_fn.lines" or die "$! ($template_compiled_fn.lines)";
		
		foreach my $line (@final_lines) {
			if ($line =~ /^(.*)(###TMOJO_(TEMPLATE_ID|LINE): .+)$/) {
				print CODE_FH "$1\n";
				print LINE_FH "$2\n";
			}
			else {
				print CODE_FH "$line\n";
				print LINE_FH ".\n";
			}
		}
		
		close CODE_FH;
		close LINE_FH;
	}
	
	# IF IT'S NOT IN THE MEMORY CACHE
	if ($cache_level < 2) {
		# DELETE THE PACKAGE
		delete_package($package_name);
		
		# PUT A CONTEXTUAL TMOJO OBJECT INTO THE PACKAGE
		{
			no strict 'refs';
			my $context_path = $normalized_template_id;
			$context_path =~ s{/[^/]+$}{};
			my $contextual_tmojo = HTML::Tmojo->new(%$self, context_path => $context_path);
			${$package_name . '::Tmojo'} = $contextual_tmojo;
		}
		
		# NOW WE DO THE FILE
		do $template_compiled_fn;
		die if $@;
		
		# REMOVE THE TEMPLATE FROM %INC (BECAUSE StatINC HURTS)
		delete $INC{$template_compiled_fn};
		
		# RECORD THE LAST TIME THAT THE PACKAGE WAS COMPILED
		$memory_cache{$package_name} = time();
	}
	
	# MAKE SURE THAT LOAD TEMPLATE HAS BEEN CALLED ON THE PARENT TEMPLATES
	{
		no strict 'refs';
		
		# MAKE SURE THAT WE DON'T HAVE AN INFINITE LOOP HERE
		if (defined $used_parents) {
			if ($used_parents->{$normalized_template_id} == 1) {
				die "circular parent reference, $normalized_template_id already used (this will cause an infinite loop)";
			}
		}
		else {
			$used_parents = {};
		}
		
		$used_parents->{$normalized_template_id} = 1;
		
		my @parents = @{$package_name . '::TMOJO_ISA'};
		
		if (@parents) {
			foreach (@parents) {
				my $contextual_tmojo = ${$package_name . '::Tmojo'};
				$_ = $contextual_tmojo->get_template_class($_, $used_parents);
			}
			
			@{$package_name . '::ISA'} = @parents;
		}
	}
	
	# RETURN THE PACKAGE NAME
	return $package_name;
}

sub normalize_template_id {
	my ($self, $template_id) = @_;
	
	# THIS IS WHERE THE MAGIC OF THE CONTEXT PATH IS RESOLVED
	if (substr($template_id, 0, 3) eq '../') {
		my $context_path = $self->{context_path};
		
		while (substr($template_id, 0, 3) eq '../') {
			$context_path =~ s{/[^/]*$}{};
			$template_id = substr($template_id, 3);
		}
		
		$template_id = "$context_path/$template_id";
	}
	elsif (substr($template_id, 0, 1) ne '/') {
		$template_id = "$self->{context_path}/$template_id";
	}
	
	# HANDLE UPWARD TRAVERSAL
	if (substr($template_id, -1, 1) eq '^') {
		$template_id = substr($template_id, 0, -1);
		
		while (rindex($template_id, '/') > 0) {
			if ($self->{template_loader}->template_exists($template_id)) {
				last;
			}
			else {
				$template_id =~ s{/[^/]+/([^/]+)$}{/$1};
			}
		}
	}
	
	# NOW WE'VE GOT OUR NAME
	return $template_id;
}

sub get_template_compiled_fn {
	my ($self, $package_name) = @_;
	
	# MAKE SURE ALL OF THE DIRECTORIES ARE THERE
	my @parts = split('::', $package_name);
	my $current_dir = $self->{cache_dir};
	
	# GET RID OF THE LAST ONE
	my $last_part = pop @parts;
	
	# MAKE ALL OF THE DIRECTORIES
	while (@parts) {
		$current_dir .= '/' . shift(@parts);
		unless (-d $current_dir) {
			mkdir $current_dir;
		}
	}
	
	my $compiled_fn = $current_dir . "/$last_part";
	
	return $compiled_fn;
}

1;
