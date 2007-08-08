# Package: AnalogSensor_Item
# $Date$
# $Revision$

=begin comment
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@

Description:

	This package provides a device-agnostic method of maintaining analog sensor
        measurement collection, contains derivative utilities and mechanisms for
        deriving state and/or associating action to sensor change.

Author:
	Gregg Liming
	gregg@limings.net

License:
	This free software is licensed under the terms of the GNU public license

Usage:

     Declaration:

        If declaring via .mht:
       
        ANALOG_SENSOR, indoor-t, indoor_temp, house_owx, Sensors, temp, hot_alarm=85, cold_alarm=62

 	'indoor-t' is an identifier for the sensor that some other software will
        require to associate sensor data to this item.  'temp' is the sensor
        type.  Currently, only 'temp' and 'humid' are supported.  Additional
        types will be added in the future. house_owx is the one-wire "conduit" that
        populates AnalogSensor_Items.  Sensors is a group.  The tag=value data
        following "temp" are tokens.  More info on use of tokens is described below.

        Alternatively, if declaring via code:

	$indoor_temp = new AnalogSensor_Item('indoor-t', 'temp');

     Operations:

	measurement(measurement,timestamp,skipdelta) - updates the measurement
		data maintained by this item if measurement, etc are provided;
		otherwise the last measurement value is returned.

	map_to_weather(weather_hash_memberi, graph_title) - copies any measurement 
                update to the Weather hash specified by weather_hash_member.
                If graph_title is supplied, it will replace the default graph title
                used by code/common/weather_rrd_update.pl to display titles.
                Note that if graph_title is used, then you must consistently use
                this with all sensors or specify the titles via the ini parm:
                weather_graph_sensor_names.

	get_average_change_rate(number_samples) - returns the average change
		rate over number_samples.  In general, number_samples should be
		> 1 since a very low delta time between previous and current
		measurement can make the change rate artificially high.
		Specifying longer numbers will provide more smoothing.  If
		fewer samples exist than number_samples, the existing number will
		be used. 

	apply_offset(offset) - applies an offset to the measurement value.  Enter
		a negative number to apply a negative offset.  This is useful to
		compensate for linear temperature shifts.

        token(tag,value) - adds "value" as a "token" to be evaluated during state
                and/or event condition checks; or, returns "token" if only "tag"
                is supplied.  A token is referenced in a condition
                using the syntax: $token_<tag> where <tag> is tag.  See 
                tie_state_condition example below.

	remove_token(tag) - removes the token from use. IMPORTANT: do not remove
                a token before first removing all conditions that depend on it.

	tie_state_condition(condition,state) - registers a condition and state value
		to be evaluated each measurement update.  If condition is true and
		the current item's state value is not "state", then the state value
		is changed to "state".  Note that tieing more than one condition
		to the same state--while supported--is discouraged as the first
		condition that "wins" is used; no mechanism exists to determine
		the order of condition evaluation.

		$indoor_temp->tie_state_condition('$measurement > 81 and $measurement < 84',hot);

                # use tokens to that the condition isn't "hardwired" to a constant
                $indoor_temp->token('danger_sp',85);
		$indoor_temp->tie_state_condition('$measurement > $token_danger_sp',dangerhot);

		In the above example, the state is changed to hot if it is not already hot AND
		the mesaurement is between 81 and 84. Similarly, the state is change to 
		dangerhot if the state is not already dangerhot and exceeds 85 degrees.
		Note that the state will not change if the measurement is greater than 84
		degrees--which is the "hot" condition--until it reaches the "dangerhot"
		condition.  This example illustrates a 1 degree hysteresis (actually, greater
		than 1 degree if the measurement updates do not provide tenths or greater
		precision).

		It is important to note in the above example that single quotes are used
		since the string "$measurement" must not be evaluated until the state
		condition is checked.  There are a number of "built-in" condition variables
		which are referenced via tokens.  The current set of tokens is:

		$measurement - the current measurement value
		$measurement_change - the difference between the previous value and the
			most recent value.  Note that this may be 0.
		$time_since_previous - the different in time between the previous value
			and the most recent value.  The resolution is milliseconds.
		$recent_change_rate - the average change rate over the last three samples
		$state - the state of the item

        measurement_change - returns the most current change of measurement values

	untie_state_condition(condition) - unregisters condition.  Unregisters all 
		conditions if condition is not provided.

	tie_event_condition(condition,event) - registers a condition and an event.
		See tie_state_condition for an explanation of condition.  event is
		the code or code reference to be evaluated if condition is true.
		Since tied event conditions are evaluated for every measurement update,
		be careful that the condition relies on change-oriented variables
		and/or that the internal logic of "event" ensure against more frequent
		execution than is desired.

	untie_event_condition(condition) - same as untie_state_condition except applied
		to tied event conditions.

	id(id) - sets id to id.  Returns id if id not present.

	type(type) - set type to type (temp or humid). Returns type if not present.

@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
=cut


package AnalogSensor_Item;
@AnalogSensor_Item::ISA = ('Generic_Item');

use Time::HiRes qw(gettimeofday);


sub new {

	my ($class, $p_id, $p_type, @p_tokens) = @_;
	my $self={};
	bless $self, $class;
	$self->id($p_id);
	$self->type($p_type);
	# maintain measurement member as it is like state
	$self->restore_data('m_measurement','m_timestamp','m_time_since_previous','m_measurement_change');
	$$self{m_max_records} = 10;
        for my $token (@p_tokens) {
           my ($tag, $value) = split(/=/,$token);
           if (defined($tag) and defined($value)) {
              print "[AnalogSensor_Item] Adding analog sensor token: $tag "
                  . "having value: $value\n" if $main::Debug{analogsensor};
              $self->token($tag, $value);
           }
        }
	return $self;
}

sub id {
	my ($self, $p_id) = @_;
	$$self{m_id} = $p_id if defined($p_id);
	return $$self{m_id};
}

sub type {
	my ($self, $p_type) = @_;
	$$self{m_type} = $p_type if $p_type;
	return $$self{m_type};
}

sub measurement {
	my ($self, $p_measurement, $p_timestamp, $p_skip_delta) = @_;
	my @measurement_records = ();
	@measurement_records = @{$$self{m_measurement_records}} if exists($$self{m_measurement_records});
	my $measurement_record = {};
	# check to see if @measurement_records exist; if not then attempt to restore
	#   from saved data
	if (!(@measurement_records)) {
		if ($$self{m_measurement}) {
			$measurement_record->{measurement} = $$self{m_measurement};
			$measurement_record->{timestamp} = $$self{m_timestamp};
			unshift @measurement_records, $measurement_record;
			$$self{m_measurement_records} = [ @ measurement_records ];
		}	
	}
	if (defined($p_measurement)) {
		$p_timestamp = gettimeofday() unless $p_timestamp; # get a timestamp if one not procided
		$p_measurement += $self->apply_offset if $self->apply_offset;
		$measurement_record->{measurement} = $p_measurement;
		$measurement_record->{timestamp} = $p_timestamp;
		# if we have a prior record, then compute the deltas
		if (!($p_skip_delta) && @measurement_records) {
			my $last_index = 0; #scalar(@measurement_records)-1;
			$$self{m_time_since_previous} = $p_timestamp -
				$measurement_records[$last_index]->{time_since_previous};
			$$self{m_measurement_change} = $p_measurement -
				$measurement_records[$last_index]->{measurement};
			# and update this record
			$measurement_record->{time_since_previous} = $$self{m_time_since_previous};
			$measurement_record->{measurement_change} = $$self{m_measurement_change};
		} else {
			$measurement_record->{time_since_previous} = 0;
			$measurement_record->{measurement_change} = 0;
		}
		unshift @measurement_records, $measurement_record;
		if (scalar(@measurement_records) > $$self{m_max_records}) {
			pop @measurement_records;
		}
# not sure the following is needed to prevent leaks
#		$$self{m_measurement_records} = undef;
		$$self{m_measurement_records} = [ @measurement_records ];
		$$self{m_measurement} = $p_measurement;
		$$self{m_timestamp} = $p_timestamp;
		$main::Weather{$self->map_to_weather} = $p_measurement 
                       if (defined($p_measurement) && ($self->map_to_weather));
		$self->check_tied_state_conditions();
		$self->check_tied_event_conditions();
	}

	return $$self{m_measurement};
}

sub get_average_change_rate {
	my ($self, $max_samples) = @_;
	my $subtotal = 0;
	my $duration = 0;
        my $max = $max_samples;
        $max = 1 unless $max_samples;
        my $index = 1;
	for my $measurement_record (@{$$self{m_measurement_records}}) {
		$subtotal += $measurement_record->{measurement_change};
		$duration += $measurement_record->{time_since_previous};
                last if $index = $max;
                $index++;
	}
	if ($duration != 0) {
		return ($subtotal/$duration);
	} else {
		return undef;
	}
}

sub measurement_change {
   my ($self) = @_;
   return $$self{m_measurement_change};
}

sub weather_to_rrd {
   my ($weather_ref) = @_;
   my $rrd_ref = lc $weather_ref;
   # this is totally ridiculous that RRD names are not the same as Weather hash refs
   # somebody was definitely not thinking
   if ($weather_ref eq 'tempoutdoor') {
       $rrd_ref = 'temp';
   } elsif ($weather_ref eq 'humidoutdoor') {
       $rrd_ref = 'humid';
   } elsif ($weather_ref eq 'tempindoor') {
       $rrd_ref = 'intemp';
   } elsif ($weather_ref eq 'humidindoor') {
       $rrd_ref = 'inhumid';
   } elsif ($weather_ref eq 'dewindoor') {
       $rrd_ref = 'indew';
   } elsif ($weather_ref eq 'dewoutdoor') {
       $rrd_ref = 'dew';
   } elsif ($weather_ref eq 'barom') {
       $rrd_ref = 'pressure';
   } elsif ($weather_ref eq 'windavgdir') {
       $rrd_ref = 'avgdir';
   } elsif ($weather_ref eq 'windgustdir') {
       $rrd_ref = 'dir';
   } elsif ($weather_ref eq 'windavgspeed') {
       $rrd_ref = 'avgspeed';
   } elsif ($weather_ref eq 'windgustspeed') {
       $rrd_ref = 'speed';
   } elsif ($weather_ref eq 'tempoutdoorapparent') {
       $rrd_ref = 'apparent';
   } elsif ($weather_ref eq 'rainrate') {
       $rrd_ref = 'rate';
   } elsif ($weather_ref eq 'raintotal') {
       $rrd_ref = 'rain';
   }
   return $rrd_ref; 
}

sub map_to_weather {
	my ($self, $p_hash_ref, $p_sensor_name) = @_;
	$$self{m_weather_hash_ref} = $p_hash_ref if $p_hash_ref;
        if ($p_sensor_name) {
          my $rrd_ref = &AnalogSensor_Item::weather_to_rrd(lc $p_hash_ref);
          my $sensor_names = $main::config_parms{weather_graph_sensor_names};
           if ($sensor_names) {
              if ($sensor_names !~ /$rrd_ref/i) {
                 $sensor_names .= ", $rrd_ref => $p_sensor_name";
                 $main::config_parms{weather_graph_sensor_names} = $sensor_names;
                 print "[AnalogSensor] weather_graph_sensor_names: $sensor_names\n" if $main::Debug{analogsensor};
              }
           } else {
              $main::config_parms{weather_graph_sensor_names} = "$rrd_ref => $p_sensor_name";
              print "[AnalogSensor] weather_graph_sensor_names: $main::config_parms{weather_graph_sensor_names}\n"
                 if $main::Debug{analogsensor};
           }
        }
	return $$self{m_weather_hash_ref};
}

sub apply_offset {
	my ($self, $p_offset) = @_;
	$$self{m_offset} = $p_offset if $p_offset;
	return $$self{m_offset};
}

sub token {
   my ($self, $p_token, $p_val) = @_;
   if ($p_token) {
      $$self{tokens}{$p_token} = $p_val if defined $p_val;
      return $$self{tokens}{$p_token} if $$self{tokens};
   }
}

sub remove_token {
   my ($self, $p_token) = @_;
   if ($p_token) {
      delete $$self{tokens}{$p_token} if exists $$self{tokens}{$p_token};
   }
}

sub tie_state_condition {
   my ($self, $condition, $state_key) = @_;
   return unless defined $state_key;
   $$self{tied_state_conditions}{$condition} = $state_key;
}

sub untie_state_condition {
   my ($self, $condition) = @_;
   if ($condition) {
      delete $self->{tied_state_conditions}{$condition}; 
   }
   else {
      delete $self->{tied_state_conditions}; # Untie em all
   }
}

sub check_tied_state_conditions {
   my ($self) = @_;
   # construct the tokens
   my $token_string = "";
   for my $token (keys %{$$self{tokens}}) {
      $token_string .= 'my $token_' . $token . ' = ' . $$self{tokens}{$token} . '; ';
   }
   print "[AnalogSensor] token_string: $token_string\n" if ($token_string) && $main::Debug{analogsensor};
   for my $condition (keys %{$$self{tied_state_conditions}}) {
      next if (defined $self->state && $$self{tied_state_conditions}{$condition} eq $self->state); 
      # expose vars for evaluating the condition
      my $measurement = $self->measurement;
      my $measurement_change = abs($self->{m_measurement_change});
      my $time_since_previous = $self->{m_time_since_previous};
      my $recent_change_rate = $self->get_average_change_rate(3);
      my $state = $self->state;
      my $code = "no strict; ";
      $code .= ($token_string) ? ($token_string . ' ' . $condition) : $condition;
      my $result = eval($code);
      if ($@) {
         &::print_log("Problem encountered when evaluating " . $self->{object_name}
            . " condition: $condition: $@");
         $self->untie_state_condition($condition);
      } elsif ($result) {
         $self->SUPER::set($$self{tied_state_conditions}{$condition});
         last;
      }
   }
}

sub tie_event_condition {
   my ($self, $condition, $event) = @_;
   return unless defined $event;
   $$self{tied_event_conditions}{$condition} = $event;
}

sub untie_event_condition {
   my ($self, $condition) = @_;
   if ($condition) {
      delete $self->{tied_event_conditions}{$condition}; 
   }
   else {
      delete $self->{tied_event_conditions}; # Untie em all
   }
}

sub check_tied_event_conditions {
   my ($self) = @_;
    # construct the tokens
   my $token_string = "";
   for my $token (keys %{$$self{tokens}}) {
      $token_string .= 'my $token_' . $token . ' = ' . $$self{tokens}{$token} . '; ';
   }
   print "[AnalogSensor] token_string: $token_string\n" if ($token_string) && $main::Debug{analogsensor};
   for my $condition (keys %{$$self{tied_event_conditions}}) {
      next if (defined $self->state && $$self{tied_event_conditions}{$condition} eq $self->state); 
      # expose vars for evaluating the condition
      my $measurement = $self->measurement;
      my $measurement_change = abs($self->{m_measurement_change});
      my $time_since_previous = $self->{m_time_since_previous};
      my $recent_change_rate = $self->get_average_change_rate(3);
      my $state = $self->state;
      my $code = "no strict; ";
      $code .= ($token_string) ? ($token_string . ' ' . $condition) : $condition;
      my $result = eval($code);
      if ($@) {
         &::print_log("Problem encountered when evaluating " . $self->{object_name}
            . " condition: $condition; $@");
         $self->untie_state_condition($condition);
      } elsif ($result) {
         package main; # needed to do this to allow usercode callbacks and vars to be used w/o needing main::
         my $code = "no strict; ";
         $code .= $$self{tied_event_conditions}{$condition};
         eval($code);
         if ($@) {
            &::print_log("Problem encountered when executing event for " . 
               $self->{object_name} . " and code: $code; $@");
         } 
         package AnalogSensor_Item;
      }
   }
}
=begin comment
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@

Description:

        This package provides is a derivative AnalogSensor to provide 'range' type functionality.

Author:
        Gregg Liming / Howard Plato
        gregg@limings.net

License:
        This free software is licensed under the terms of the GNU public license
Usage:

     Declaration:

        If declaring via .mht:

        ANALOG_SENSOR_R, attribute, object, xap instance, group, type, alert_lo, warning_low, warning_high, alert_high

        'attribute' is an identifier for the sensor that some other software will
        require to associate sensor data to this item.  'type' is the sensor
        type.  Currently, only 'temp' and 'humid' are supported from owx, and 
	disk, network, cpu, temps, swap, and memory from sdx. Additional
        types will be added in the future. xap instance is the xap "conduit" that
        populates AnalogRangeSensor_Items.  group is a group. The ranges work out as follows:

	state = alert_low    if measurement < alert_low
	state = warning_low  if alert_low < measurement < warning_low
	state = normal       if warning_low < measurement < warning_high
	state = warning_high if warning_high < measurement < alert_high
	state = alert_high   if measurement > alert_high

	note if the sensor is not upper or lower bound, then the appropriate bounds should be
	omitted.

        Alternatively, if declaring via code:

        $server_hda1 = new AnalogRangeSensor_Item('sda1.free', 'disk', 50000, 100000);
	$server_load = new AnalogRangeSensor_Item('loadavg1', 'cpu', , , 4, 6);

	TODO: More generic states if requested
 
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
=cut

package AnalogRangeSensor_Item;

@AnalogRangeSensor_Item::ISA = ('AnalogSensor_Item');

sub new {
   my ($class, $id, $sensor_type, @r_tokens ) = @_;
   my $self = &AnalogSensor_Item::new($class, $id, $sensor_type);

   my %states;
   my %diag_config;
        for my $token (@r_tokens) {
           my ($tag, $value) = split(/=/,$token);
           if (defined($tag) and defined($value)) {
              print "[AnalogRangeSensor_Item] Adding analog sensor token: $tag "
                  . "having value: $value\n" if $main::Debug{analogsensor};
              $diag_config{$tag} = $value;
           }
        }
   my $alert_low = $diag_config{'alert_lo'};
   my $warning_low = $diag_config{'warning_lo'};
   my $warning_high = $diag_config{'warning_hi'};
   my $alert_high = $diag_config{'alert_hi'};

   # it would also be good to pass along other tokens specified

   # down the road, would be nice to make configurable.
   # ..., normal => 3-5, warning => 2-6, critical => x-10, error => 1-x 

   # five states supported for now
   # 
   # alert low  | warning low |  normal  | warning high |  alert high
   # ----------------------------------------------------------------
   #
   # it may also be desirable to 'squash' states: alert_low or alert_high = alert, etc...

   $states{"alert_low"} = "alert_low";
   $states{"alert_high"} = "alert_high";

   $states{"warning_low"} = "warning_low";
   $states{"warning_high"} = "warning_high";

   $states{"normal"} = "normal";


   &::print_log( "[AnalogRangeSensor_Item] Specified ranges for " . $self->{object_name} . " : $alert_low,$warning_low,$warning_high,$alert_high") if $main::Debug{analogsensor};

   #if ($diag_config) { #need to put this back
      my $condition;
      my $normal_condition = "";

      # alert conditions
      if (defined($alert_low)) {
         $self->token('alert_lo',$alert_low);
         $condition = '$measurement < $token_alert_lo';
print "[AnalogRangeSensor_Item] Condition Alert_low: $condition \n"  if $main::Debug{analogsensor};
	 $self->tie_state_condition("$condition", $states{"alert_low"})
      }
      if (defined($alert_high)) {
         $self->token('alert_hi',$alert_high);
         $condition = '$measurement > $token_alert_hi';
print "[AnalogRangeSensor_Item] Condition Alert_High: $condition \n" if $main::Debug{analogsensor};
	 $self->tie_state_condition("$condition", $states{"alert_high"})
      }

      # warning conditions

      if (defined($warning_low)) {
            $self->token('warning_lo',$warning_low);
	    $condition = '$measurement < $token_warning_lo';
	    if (defined($alert_low)) {
		$condition .= ' and $measurement > $token_alert_lo';
	    }
print "[AnalogRangeSensor_Item] Condition Warning_Low: $condition \n" if $main::Debug{analogsensor};
            $self->tie_state_condition("$condition",$states{"warning_low"});
      }
      if (defined($warning_high)) {
            $self->token('warning_hi',$warning_high);
	    $condition = '$measurement > $token_warning_hi';
	    if (defined($alert_high)) {
		$condition .= ' and $measurement < $token_alert_hi';
	    }
print "[AnalogRangeSensor_Item] Condition Warning_High: $condition \n" if $main::Debug{analogsensor};
            $self->tie_state_condition("$condition",$states{"warning_high"});
      }
      #normal condition
      $normal_condition .=  '($measurement > $token_alert_lo)' if (defined($alert_low));
      $normal_condition .= " and " if ((defined($alert_low)) and (defined($warning_low)));
      $normal_condition .=  '($measurement > $token_warning_lo)' if (defined($warning_low));
      $normal_condition .= " and " if ((defined($warning_low)) and (defined($warning_high)));
      $normal_condition .=  '($measurement < $token_warning_hi)' if (defined($warning_high));
      $normal_condition .= " and " if ((defined($warning_high)) and (defined($alert_high)));
      $normal_condition .=  '($measurement < $token_alert_hi)' if (defined($alert_high));

print "[AnalogRangeSensor_Item] Condition Normal: $condition \n" if $main::Debug{analogsensor};
      $self->tie_state_condition("$normal_condition",$states{"normal"});

      $self->check_tied_state_conditions();
   #}

   return $self;
}


1;
