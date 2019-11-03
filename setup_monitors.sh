#!/bin/bash

LEFT_MONITOR_EDID="00ffffffffffff004c2dcc0bffffffff ffff0104b54728783ae691a7554ea025"
RIGHT_MONITOR_EDID="00ffffffffffff004c2dcc0b30303030 27180104b54728783ae691a7554ea025"

LEFT_DP=""
RIGHT_DP=""

# find first occurrence of one of the above EDIDs
# once found, move backwards until we find the DP-X-X
# set resolution once found DP-X-X.

XRANDR_PROPERTIES=$(xrandr --prop)

FOUND_EDP=false
EDP_VALUE=""

FOUND_DP=false
DP_VALUE=""

FOUND_EDID=false
FOUND_EDID_VALUE=false
EDID_VALUE=""

while read -r LINE; do
	if [[ "$FOUND_EDP" = false && ( $LINE =~ ^(eDP-[0-9])[[:space:]] || $LINE =~ ^(eDP[0-9])[[:space:]] ) ]]; then
		EDP_VALUE=${BASH_REMATCH[1]}
		echo $EDP_VALUE	
		FOUND_EDP=true
	fi

	if [[ $LINE =~ ^(DP-[0-9]-[0-9])[[:space:]] ]] || [[ $LINE =~ ^(DP[0-9]-[0-9])[[:space:]] ]]; then
		DP_VALUE=${BASH_REMATCH[1]}	
		FOUND_DP=true
	fi

	if [ "$FOUND_EDID" = true ]; then
		if [ -z "$EDID_VALUE" ]; then
			EDID_VALUE=$(echo $LINE | cut -c1-32)
		else
			EDID_VALUE="${EDID_VALUE} $(echo $LINE | cut -c1-32)"
			FOUND_EDID_VALUE=true
		fi
	fi

	if [ "$FOUND_DP" = true ] && [[ $LINE =~ ^EDID: ]]; then
		FOUND_EDID=true
	fi

	if [ "$FOUND_DP" = true ] && [ "$FOUND_EDID_VALUE" = true ]; then
		echo $DP_VALUE $EDID_VALUE

		if [ "$EDID_VALUE" == "$LEFT_MONITOR_EDID" ]; then
			LEFT_DP=${DP_VALUE}
		fi

		if [ "$EDID_VALUE" == "$RIGHT_MONITOR_EDID" ]; then
			RIGHT_DP=${DP_VALUE}
		fi

		FOUND_DP=false
		FOUND_EDID=false
		FOUND_EDID_VALUE=false
		
		DP_VALUE=""
		EDID_VALUE=""
	fi

done <<< "$XRANDR_PROPERTIES"

if [[ ! -z "$LEFT_DP" ]] && [[ ! -z "$RIGHT_DP" ]] && [[ ! -z "$EDP_VALUE" ]]; then
	echo "Found two external monitors, and one internal monitor!"
else
	echo $LEFT_DP $RIGHT_DP $EDP_VALUE
	echo "Did not find expected monitors!"
	exit 1
fi

# reset
xrandr -s 0

# set
xrandr --output $EDP_VALUE --off
xrandr --output $LEFT_DP --mode 2560x1440 --rate 59.95 --rotate left
xrandr --output $RIGHT_DP --mode 2560x1440 --rate 59.95 --pos 1440x850 --primary

gsettings set org.gnome.shell.extensions.dash-to-dock multi-monitor true

exit
