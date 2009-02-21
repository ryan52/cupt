package Cupt::System::Resolver;

use 5.10.0;
use strict;
use warnings;

use Cupt::Core;
use Cupt::Cache::Relation qw(stringify_relation_or_group);

=head1 FIELDS

=head2 config

stores reference to config (Cupt::Config)

=head2 cache

stores reference to cache (Cupt::Cache)

=head2 params

parameters that configure resolver's actions:

=head3 no-remove

disallow removing packages for resolving dependencies

=head2 _packages

hash { I<package_name> => {S<< 'version' => I<version> >>, S<< 'stick' => I<stick> >>} }

where:

I<package_name> - name of binary package

I<version> - reference to Cupt::Cache::BinaryVersion, can
be undefined if package has to be removed

I<stick> - a boolean flag to
indicate can resolver modify this item or not

=head2 pending_relations

array of relations which are to be satisfied by final resolver, used for
filling depends, recommends (optionally), suggests (optionally) of requested
packages, or for satisfying some requested relations

=cut

use fields qw(config cache params _packages pending_relations);

=head1 METHODS

=head2 new

creates new resolver

Parameters: 

I<config> - reference to Cupt::Config

I<cache> - reference to Cupt::Cache

=cut

sub new {
	my $class = shift;
	my $self = fields::new($class);

	# common apt config
	$self->{config} = shift;

	$self->{cache} = shift;

	# resolver params
	%{$self->{params}} = (
		'no-remove' => 0,
	);

	$self->{pending_relations} = [];

	return $self;
}

=head2 set_params

member function, sets params for the resolver

Parameters: hash (as list) of params and their values

Example: C<< $resolver->set_params('no-remove' => 1); >>

=cut

sub set_params {
	my ($self) = shift;
	while (@_) {
		my $key = shift;
		my $value = shift;
		$self->{config}->{$key} = $value;
	}
}

=head2 import_installed_versions

member function, imports already installed versions, usually used in pair with
C<&Cupt::System::State::export_installed_versions>

Parameters: 

I<ref_versions> - reference to array of Cupt::Cache::BinaryVersion

=cut

sub import_installed_versions ($$) {
	my ($self, $ref_versions) = @_;

	foreach my $version (@$ref_versions) {
		# just moving versions to packages, don't try install or remove some dependencies
		$self->{_packages}->{$version->{package_name}}->{version} = $version;
	}
}

sub _schedule_new_version_relations ($$) {
	my ($self, $version) = @_;

	# unconditionally adding pre-depends
	foreach (@{$version->{pre_depends}}) {
		$self->_auto_satisfy_relation($_);
	}
	# unconditionally adding depends
	foreach (@{$version->{depends}}) {
		$self->_auto_satisfy_relation($_);
	}
	if ($self->{config}->var('apt::install-recommends')) {
		# ok, so adding recommends
		foreach (@{$version->{recommends}}) {
			$self->_auto_satisfy_relation($_);
		}
	}
	if ($self->{config}->var('apt::install-suggests')) {
		# ok, so adding suggests
		foreach (@{$version->{suggests}}) {
			$self->_auto_satisfy_relation($_);
		}
	}
}

# installs new version, shedules new dependencies, but not sticks it
sub _install_version_no_stick ($$) {
	my ($self, $version) = @_;
	if (exists $self->{_packages}->{$version->{package_name}} &&
		exists $self->{_packages}->{$version->{package_name}}->{stick})
	{
		# package is restricted to be updated
		return;
	}

	$self->{_packages}->{$version->{package_name}}->{version} = $version;
	if ($self->{config}->var('debug::resolver')) {
		mydebug("install package '$version->{package_name}', version '$version->{version_string}'");
	}
	$self->_schedule_new_version_relations($version);
}

=head2 install_version

member function, installs a new version with requested depends

Parameters:

I<version> - reference to Cupt::Cache::BinaryVersion

=cut

sub install_version ($$) {
	my ($self, $version) = @_;
	$self->_install_version_no_stick($version);
	$self->{_packages}->{$version->{package_name}}->{stick} = 1;
	$self->{_packages}->{$version->{package_name}}->{manually_selected} = 1;
}

=head2 satisfy_relation

member function, installs all needed versions to satisfy relation or relation group

Parameters:

I<relation_expression> - reference to Cupt::Cache::Relation, or relation OR
group (see documentation for Cupt::Cache::Relation for the info about OR
groups)

=cut

sub satisfy_relation ($$) {
	my ($self, $relation_expression) = @_;

	# FIXME: implement dummy package dependencies
	$self->_auto_satisfy_relation($relation_expression);
}

sub _auto_satisfy_relation ($$) {
	my ($self, $relation_expression) = @_;

	my $ref_satisfying_versions = $self->{cache}->get_satisfying_versions($relation_expression);
	if (!__is_version_array_intersects_with_packages($ref_satisfying_versions, $self->{_packages})) {
		# if relation is not satisfied
		if ($self->{config}->var('debug::resolver')) {
			my $message = "auto-installing relation '";
			$message .= stringify_relation_or_group($relation_expression);
			$message .= "'";
			mydebug($message);
		}
		push @{$self->{pending_relations}}, $relation_expression;
	}
}

=head2 remove_package

member function, removes a package

Parameters:

I<package_name> - string, name of package to remove

=cut

sub remove_package ($$) {
	my ($self, $package_name) = @_;
	$self->{_packages}->{$package_name}->{version} = undef;
	$self->{_packages}->{$package_name}->{stick} = 1;
	$self->{_packages}->{$package_name}->{manually_selected} = 1;
	if ($self->{config}->var('debug::resolver')) {
		mydebug("removing package $package_name");
	}
}

=head2 upgrade

member function, schedule upgrade of as much packages in system as possible

No parameters.

=cut

sub upgrade ($) {
	my ($self) = @_;
	foreach (keys %{$self->{_packages}}) {
		my $package_name = $_;
		my $package = $self->{cache}->get_binary_package($package_name);
		my $original_version = $self->{_packages}->{$package_name}->{version};
		my $supposed_version = $self->{cache}->get_policy_version($package);
		# no need to install the same version
		$original_version->{version_string} ne $supposed_version->{version_string} or next;
		$self->_install_version_no_stick($supposed_version);
	}
}

# every package version has a weight
sub _package_weight ($$$) {
	my ($self, $package_name, $version) = @_;
	return 0 if !defined $version;
	if ($version->is_installed() && $self->{cache}->is_automatically_installed($package_name)) {
		# automatically installed packages count nothing for user
		return 0;
	}
	my $result = $self->{cache}->get_pin($version);
	$result += 5000 if defined($version->{essential});
	$result += 2000 if $version->{priority} eq 'required';
	$result += 1000 if $version->{priority} eq 'important';
	$result += 400 if $version->{priority} eq 'standard';
	$result += 100 if $version->{priority} eq 'optional';
}

sub __is_version_array_intersects_with_packages ($$) {
	my ($ref_versions, $ref_packages) = @_;

	foreach my $version (@$ref_versions) {
		exists $ref_packages->{$version->{package_name}} or next;

		my $installed_version = $ref_packages->{$version->{package_name}}->{version};
		defined $installed_version or next;
		
		return 1 if $version->{version_string} eq $installed_version->{version_string};
	}
	return 0;
}

sub __clone_packages ($) {
	my ($ref_packages) = @_;

	my %clone;
	foreach (keys %$ref_packages) {
		my %ref_new_package_entry = %{$ref_packages->{$_}};
		$clone{$_} = \%ref_new_package_entry;
	}
	return \%clone;
}

sub _resolve ($$) {
	my ($self, $sub_accept) = @_;

	if ($self->{config}->var('debug::resolver')) {
		mydebug("started resolving");
	}

	# [ 'packages' => {
	#                         package_name... => {
	#                                           'version' => version,
	#                                           'stick' (optional),
	#                                           'manually_installed' (optional),
	#                                         }
	#                       }
	#   'score' => score
	#   'level' => level
	# ]...
	my @solution_entries = ({ packages => __clone_packages($self->{_packages}), score => 0, level => 0 });
	my $selected_solution_entry_index = 0;

	# for each package entry 'count' will contain the number of failures
	# during processing these package
	# { package_name => count }...
	my %failed_counts;

	my $check_failed;

	# will be filled in MAIN_LOOP
	my $package_entry;
	my $package_name;

	my $sub_mydebug_wrapper = sub {
		mydebug(" " x (scalar $solution_entries[$selected_solution_entry_index]->{level}) . "@_");
	};

	# debugging subroutine
	my $sub_debug_version_change = sub {
		my ($package_name, $supposed_version, $original_version) = @_;

		my $old_version_string = defined($original_version) ? $original_version->{version_string} : '<not installed>';
		my $new_version_string = defined($supposed_version) ? $supposed_version->{version_string} : '<not installed>';
		my $message = "trying: package '$package_name': '$old_version_string' -> '$new_version_string'";
		$sub_mydebug_wrapper->($message);
	};

	my $sub_apply_action = sub {
		my ($ref_solution_entry, $ref_action_to_apply) = @_;

		my $package_name_to_change = $ref_action_to_apply->[0];
		my $supposed_version = $ref_action_to_apply->[1];
		my $ref_package_entry_to_change = $ref_solution_entry->{packages}->{$package_name_to_change};
		my $original_version = $ref_package_entry_to_change->{version};

		if ($self->{config}->var('debug::resolver')) {
			$sub_debug_version_change->($package_name_to_change, $supposed_version, $original_version);
		}

		# raise the level
		++$ref_solution_entry->{level};

		# set stick for change for the time on underlying solutions
		$ref_package_entry_to_change->{stick} = 1;
		$ref_package_entry_to_change->{version} = $supposed_version;
	};

	do {
		# continue only if we have at least one solution pending, otherwise we have a great fail
		scalar @solution_entries or return 0;

		# possible actions to resolve dependencies if needed
		# array of [ package_name, version ]
		my @possible_actions;

		$selected_solution_entry_index = 0;
		my $ref_current_solution_entry = $solution_entries[$selected_solution_entry_index];

		my $ref_current_packages = $ref_current_solution_entry->{packages};

		my $package_name;

		# clearing check_failed
		$check_failed = 0;

		# to speed up the complex decision steps, if solution stack is not
		# empty, firstly check the packages that had a problem
		my @packages_in_order = sort {
			($failed_counts{$b} // 0) <=> ($failed_counts{$a} // 0)
		} keys %$ref_current_packages;

		MAIN_LOOP:
		foreach (@packages_in_order) {
			$package_name = $_;
			$package_entry = $ref_current_packages->{$package_name};
			my $version = $package_entry->{version};
			defined $version or next;

			# checking that all 'Depends' are satisfied
			foreach (@{$version->{depends}}, @{$version->{pre_depends}}) {
				# check if relation is already satisfied
				my $ref_satisfying_versions = $self->{cache}->get_satisfying_versions($_);
				if (__is_version_array_intersects_with_packages($ref_satisfying_versions, $ref_current_packages)) {
					# good, nothing to do
				} else {
					# for resolving we can do:

					# install one of versions package needs
					foreach my $satisfying_version (@$ref_satisfying_versions) {
						if (!exists $ref_current_packages->{$satisfying_version->{package_name}}->{stick}) {
							push @possible_actions, [ $satisfying_version->{package_name}, $satisfying_version ];
						}
					}

					if (!exists $package_entry->{stick}) {
						# change version of the package
						my $other_package = $self->{cache}->get_binary_package($package_name);
						foreach my $other_version (@{$other_package->versions()}) {
							# don't try existing version
							next if $other_version->{version_string} eq $version->{version_string};

							push @possible_actions, [ $package_name, $other_version ];
						}

						if (!$self->{config}->{'no-remove'} || !$version->is_installed()) {
							# remove the package
							push @possible_actions, [ $package_name, undef ];
						}
					}

					if ($self->{config}->var('debug::resolver')) {
						my $stringified_relation = stringify_relation_or_group($_);
						$sub_mydebug_wrapper->("problem: package '$package_name': " . 
								"unsatisfied depends '$stringified_relation'");
					}
					$check_failed = 1;

					if (scalar @possible_actions == 1) {
						# only one solution is available
						if ($self->{config}->var('debug::resolver')) {
							$sub_mydebug_wrapper->("only one solution available");
						}
						$sub_apply_action->($ref_current_solution_entry, $possible_actions[0]);
						@possible_actions = ();
						next MAIN_LOOP;
					}
					last MAIN_LOOP;
				}
			}

			# checking that all 'Conflicts' are not satisfied
			foreach (@{$version->{conflicts}}) {
				# check if relation is accidentally satisfied
				my $ref_satisfying_versions = $self->{cache}->get_satisfying_versions($_);

				if (!__is_version_array_intersects_with_packages($ref_satisfying_versions, $ref_current_packages)) {
					# good, nothing to do
				} else {
					# so, this can conflict... check it deeper on the fly
					my $conflict_found = 0;
					foreach my $satisfying_version (@$ref_satisfying_versions) {
						my $other_package_name = $satisfying_version->{package_name};

						# package can't conflict with itself
						$other_package_name ne $package_name or next;

						# is the package installed?
						exists $ref_current_packages->{$other_package_name} or next;

						my $other_package_entry = $ref_current_packages->{$other_package_name};

						# does the stick exists?
						!exists $other_package_entry->{stick} or next;
						# does the package have an installed version?
						defined($other_package_entry->{version}) or next;
						# is this our version?
						$other_package_entry->{version}->{version_string} eq $satisfying_version->{version_string} or next;

						$conflict_found = 1;
						# yes... so change it
						my $other_package = $self->{cache}->get_binary_package($other_package_name);
						foreach my $other_version (@{$other_package->versions()}) {
							# don't try existing version
							next if $other_version->{version_string} eq $satisfying_version->{version_string};

							push @possible_actions, [ $other_package_name, $other_version ];
						}

						if (!$self->{config}->{'no-remove'} || !exists $other_package_entry->{installed}) {
							# or remove it
							push @possible_actions, [ $other_package_name, undef ];
						}
					}

					if ($conflict_found) {
						$check_failed = 1;
						if (!exists $package_entry->{stick}) {
							# change version of the package
							my $package = $self->{cache}->get_binary_package($package_name);
							foreach my $other_version (@{$package->versions()}) {
								# don't try existing version
								next if $other_version->{version_string} eq $version->{version_string};

								push @possible_actions, [ $package_name, $other_version ];
							}
							
							if (!$self->{config}->{'no-remove'} || !exists $package_entry->{installed}) {
								# remove the package
								push @possible_actions, [ $package_name, undef ];
							}
						}

						if ($self->{config}->var('debug::resolver')) {
							my $stringified_relation = stringify_relation_or_group($_);
							$sub_mydebug_wrapper->("problem: package '$package_name': " . 
									"satisfied conflicts '$stringified_relation'");
						}
						last MAIN_LOOP;
					}
				}
			}
		}

		if (!$check_failed) {
			# suggest found solution
			my $user_answer = $sub_accept->($ref_current_packages);
			if (!defined $user_answer) {
				# exiting...
				return undef;
			} elsif ($user_answer) {
				# yeah, this is end of our tortures
				if ($self->{config}->var('debug::resolver')) {
					$sub_mydebug_wrapper->("accepted");
				}
				return 1;
			} else {
				# caller hasn't accepted this solution, well, go next...
				$check_failed = 1;
				if ($self->{config}->var('debug::resolver')) {
					$sub_mydebug_wrapper->("declined");
					# purge current solution
					splice @solution_entries, $selected_solution_entry_index, 1;
					next;
				}
			}
		}

		if (scalar @possible_actions) {
			# firstly rank all solutions
			foreach (@possible_actions) {
				my $package_name = $_->[0];
				my $supposed_version = $_->[1];
				my $original_version = exists $ref_current_packages->{$package_name} ?
						$ref_current_packages->{$package_name}->{version} : undef;

				my $supposed_version_weight = $self->_package_weight($package_name, $supposed_version);
				my $original_version_weight = $self->_package_weight($package_name, $original_version);

				# 3rd field in the structure will be "profit" of the change
				push @$_, $supposed_version_weight - $original_version_weight;
			}

			# sort them by "rank", from more bad to more good
			@possible_actions = sort { $a->[2] <=> $b->[2] } @possible_actions;

			my @forked_solution_entries;
			# fork the solution entry and apply all the solutions by one
			foreach my $idx (0..$#possible_actions) {
				my $ref_cloned_solution_entry;
				if ($idx == $#possible_actions) {
					# use existing solution entry
					$ref_cloned_solution_entry = $ref_current_solution_entry;
				} else {
					# clone the current stack to form a new one
					# we can obviously use Storable::dclone, or Clone::Clone here, but speed...
					$ref_cloned_solution_entry = {
						packages => __clone_packages($ref_current_solution_entry->{packages}),
						level => $ref_current_solution_entry->{level},
						score => $ref_current_solution_entry->{score},
					};
					push @forked_solution_entries, $ref_cloned_solution_entry;
				}

				my $ref_action_to_apply = $possible_actions[$idx];
				# apply the solution
				$sub_apply_action->($ref_cloned_solution_entry, $ref_action_to_apply);
			}

			# adding forked solutions to main solution storage just after current solution
			splice @solution_entries, $selected_solution_entry_index+1, 0, reverse @forked_solution_entries;
		} else {
			if ($self->{config}->var('debug::resolver')) {
				$sub_mydebug_wrapper->("no solution for broken package $package_name");
			}
			# mark package as failed one more time
			++$failed_counts{$package_name};
			# purge current solution
			splice @solution_entries, $selected_solution_entry_index, 1;
		}
	} while $check_failed;
}

=head2 resolve

member function, finds a solution for requested actions

Parameters:

I<sub_accept> - reference to subroutine which have return true if solution is
accepted, and false otherwise

Returns:

true if some solution was found and accepted, false otherwise

=cut

sub resolve ($$) {
	my ($self, $sub_accept) = @_;

	# unwinding relations
	while (scalar @{$self->{pending_relations}}) {
		my $relation_expression = shift @{$self->{pending_relations}};
		my $ref_satisfying_versions = $self->{cache}->get_satisfying_versions($relation_expression);
		
		# if we have no candidates, skip the relation
		scalar @$ref_satisfying_versions or next;

		# installing most preferrable version

		my $version_to_install = $ref_satisfying_versions->[0];
		if ($self->{config}->var('debug::resolver')) {
			mydebug("selected package '%s', version '%s' for relation expression '%s'",
					$version_to_install->{package_name},
					$version_to_install->{version_string},
					stringify_relation_or_group($relation_expression)
			);
		}
		$self->_install_version_no_stick($version_to_install);
		# note that _install_version_no_stick can add some pending relations
	}

	# at this stage we have all extraneous dependencies installed, now we should check inter-depends
	return $self->_resolve($sub_accept);
}

1;

