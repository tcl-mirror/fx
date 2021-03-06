## -*- tcl -*-
# # ## ### ##### ######## ############# ######################

# @@ Meta Begin
# Package fx::fossil 0
# Meta author      {Andreas Kupries}
# Meta category    ?
# Meta description ?
# Meta location    https://core.tcl-lang.org/akupries/fx
# Meta platform    tcl
# Meta require     sqlite3
# Meta subject     fossil
# Meta summary     ?
# @@ Meta End

package require Tcl 8.5
package require sqlite3
package require cmdr::color
package require debug
package require debug::caller

package require fx::table
package require fx::atexit

debug level  fx/fossil
debug prefix fx/fossil {[debug caller] | }

# # ## ### ##### ######## ############# ######################

namespace eval ::fx {
    namespace export fossil
    namespace ensemble create
}
namespace eval ::fx::fossil {
    namespace export \
	c_show_repository c_set_repository c_reset_repository \
	c_default_repository test-tags test-branch test-last-uuid \
	test-schema test-mlink branch-of changeset date-of last-uuid \
	reveal user-info users user-config get-manifest fx-tables \
	fx-maps fx-map-keys fx-map-get fx-enums fx-enum-items \
	ticket-title ticket-fields global global-location \
	show-global-location repository repository-location \
	show-repository-location set-repository-location \
	repository-find repository-open global-has has empty \
	global-empty exchange schema has-ext-mlink
	
    namespace ensemble create

    namespace import ::cmdr::color
    namespace import ::fx::atexit
    namespace import ::fx::table::do
    rename do table

    # Cached location of the repository we are working with.
    variable repo_location {}
    # Information about where the location came from (one of 'user',
    # 'checkout', or 'default').
    variable repo_origin {}

    # Location of a fossil binary for things we are shelling out to
    # (still, although only 'get-manifest' does).
    variable fossil [auto_execok fossil]

    # Configuration key used to save/read the current repository.
    variable rkey "fx-aku-current-repository"
}

# # ## ### ##### ######## ############# ######################

proc ::fx::fossil::test-branch {config} {
    debug.fx/fossil {}
    show-repository-location
    puts [branch-of [$config @uuid]]
    return
}

proc ::fx::fossil::test-tags {config} {
    debug.fx/fossil {}
    show-repository-location

    set uuid [$config @uuid]
    [table t {{Tag Name} Type Value} {
	repository eval {
	    SELECT T.tagname AS name,
	           X.tagtype AS type,
	           X.value AS value
	    FROM  blob    B,
	          tagxref X,
	          tag     T
	    WHERE B.uuid  = :uuid
	    AND   B.rid   = X.rid
	    AND   X.tagid = T.tagid
	} {
	    $t add $name $type $value
	}
    }] show puts
    return
}

proc ::fx::fossil::test-last-uuid {config} {
    debug.fx/fossil {}
    show-repository-location
    puts [last-uuid]
    return
}

proc ::fx::fossil::test-schema {config} {
    debug.fx/fossil {}
    show-repository-location
    puts [schema]
    return
}

proc ::fx::fossil::test-mlink {config} {
    debug.fx/fossil {}
    show-repository-location
    puts [expr {[has-ext-mlink]
		? "Extended mlink"
		: "Basic mlink"}]
    return
}

# # ## ### ##### ######## ############# ######################

proc ::fx::fossil::c_show_repository {config} {
    debug.fx/fossil {}
    show-repository-location
    return
}

proc ::fx::fossil::c_set_repository {config} {
    debug.fx/fossil {}
    variable rkey
    # Note that we are effectively inlining the command
    #    "fx::mgr::config::set-global".
    # We have to, to avoid a dependency cycle with fx::mgr::config.

    # Determine location, as absolute path.
    set location [file normalize [$config @target]]

    # Save to external global configuration
    global eval {
	INSERT OR IGNORE INTO global_config
	VALUES (:rkey, :location);

	UPDATE global_config
	SET   value = :location
	WHERE name  = :rkey
    }

    # Update in-memory information, for the display following.
    clear-repository-location
    set-repository-location $location default

    show-repository-location
    return
}

proc ::fx::fossil::c_reset_repository {config} {
    debug.fx/fossil {}
    variable rkey
    # Note that we are effectively inlining the commands
    #    "fx::mgr::config::unset-global", and "...::has-global".
    # We have to, to avoid a dependency cycle with fx::mgr::config.

    # Load current default, if there is any. Abort early if not.
    set havedefault 0
    global eval {
	SELECT value AS location
	FROM  global_config
	WHERE name  = :rkey
    } {
	incr havedefault
	clear-repository-location
	set-repository-location $location default
	debug.fx/fossil {==> default $location}
    }

    if {!$havedefault} {
	puts [color warning {No default repository known, done nothing}]
	return
    }

    # Remove from external configuration.
    global eval {
	DELETE
	FROM global_config
	WHERE name = :rkey
    }

    # Show what was unset, and clear from memory as well.
    show-repository-location " [color warning {Now unset}]"
    clear-repository-location
    return
}

proc ::fx::fossil::c_default_repository {config} {
    debug.fx/fossil {}
    variable rkey
    # Note that we are effectively inlining the commands
    #    "fx::mgr::config::has-global".
    # We have to, to avoid a dependency cycle with fx::mgr::config.

    # Load current default, if there is any. Abort early if not.
    set havedefault 0
    global eval {
	SELECT value AS location
	FROM  global_config
	WHERE name  = :rkey
    } {
	incr havedefault
	clear-repository-location
	set-repository-location $location default
	debug.fx/fossil {==> default $location}
    }

    if {!$havedefault} {
	puts [color warning {No default repository known}]
	return
    }

    # Show the current setting, and clear it from memory again.
    show-repository-location
    clear-repository-location
    return
}

# # ## ### ##### ######## ############# ######################
## Commands for global and repository databases.

proc ::fx::fossil::global {args} {
    debug.fx/fossil {1st call, create and short-circuit all following}
    # Drop the procedure.
    rename ::fx::fossil::global {}

    # And replace it with the database command.
    set location [global-location]
    sqlite3 ::fx::fossil::global $location
    atexit add [list ::fx::fossil::GlobalClose $location]

    if {![llength $args]} return

    # Run the new database on the arguments.
    try {
	set r [uplevel 1 [list ::fx::fossil::global {*}$args]]
    } on return {e o} {
	# tricky code here. We have to rethrow with -code return to
	# keep the semantics in case we are called with the
	# 'transaction' method here, which passes a 'return' of the
	# script as its own 'return', and we must do the same here.
	return {*}$o -code return $e
    }
    return $r
}

proc ::fx::fossil::GlobalClose {location} {
    debug.fx/fossil {AtExit}
    ::fx::fossil::global close
    return
}

proc ::fx::fossil::repository {args} {
    debug.fx/fossil {fail}
    # This procedure will be overwritten by 'repository-open' below.
    ::global argv0
    return -code error \
	-errorcode {FX FOSSIL REPOSITORY UNKNOWN} \
	"[file tail $argv0] was not able to determine the repository"
}

# # ## ### ##### ######## ############# ######################

proc ::fx::fossil::repository-open {p} {
    debug.fx/fossil {}
    # cmdr generate callback

    # NOTE how we are keeping the repository database until process
    # end. We assume that this command is called only once. See also
    # the fx cmdr specification (fx.tcl).

    set location [$p config @repository]

    # Note: If the repository was not specified the search process
    # will have already set the variable below. However for a
    # user-specified location the search did not happen, leaving it
    # uninitialized. So we do that now, making sure.
    set-repository-location $location user

    debug.fx/fossil {@ $location}
    if {$location eq {}} {
	# Do not create a repository db if we have no location for it
	# (see repo-location below, use case "all").
	return {}
    }

    sqlite3 ::fx::fossil::repository $location
    atexit add [list ::fx::fossil::RepositoryClose $location]
    # Set a timeout for in case we run into a locked database. This
    # allows us to wait this long for the lock to clear before
    # aborting, instead of failing immediately.
    ::fx::fossil::repository timeout 5000
    return  ::fx::fossil::repository
}

proc ::fx::fossil::RepositoryClose {location} {
    debug.fx/fossil {AtExit}
    ::fx::fossil::repository close
    return
}

# # ## ### ##### ######## ############# ######################

proc ::fx::fossil::show-global-location {{suffix {}}} {
    debug.fx/fossil {}
    puts "[color warning Global] @ [color note [global-location]]$suffix"
    return
}

proc ::fx::fossil::global-location {} {
    debug.fx/fossil {}
    return [file normalize ~/.fossil]
}

proc ::fx::fossil::show-repository-location {{suffix {}}} {
    debug.fx/fossil {}
    variable repo_location
    variable repo_origin
    puts "[color warning [string totitle $repo_origin]] @ [color note $repo_location]$suffix"
    return
}

proc ::fx::fossil::repository-location {} {
    variable repo_location
    debug.fx/fossil {@ $repo_location}
    return  $repo_location
}

proc ::fx::fossil::set-repository-location {path origin} {
    debug.fx/fossil {@ $origin ($path)}
    variable repo_location
    variable repo_origin

    # Skip when already defined.
    if {$repo_origin ne {}} return

    set repo_location $path
    set repo_origin   $origin
    return
}

proc ::fx::fossil::clear-repository-location {} {
    debug.fx/fossil {}
    variable repo_location {}
    variable repo_origin   {}
    return
}

proc ::fx::fossil::repository-find {p} {
    debug.fx/fossil {}
    # cmdr generate callback

    if {![$p config @repository-active]} {
	debug.fx/fossil {<no-search>}
	return {}
    }

    # NOTE how we are keeping the checkout database until process end.
    # Assumes that locate is called only once. See also fx cmdr
    # specification.

    # Get checkout directory and database.
    try {
	set ckout [ckout [scan-up Repository [pwd] fx::fossil::is]]
	debug.fx/fossil {checkout located @ $ckout}
    } trap {FX FOSSIL SCAN-UP}  {e o} - \
      trap {FX FOSSIL CHECKOUT} {e o} {
	# Check if a target is set. If yes, use that as our
	# repository. Otherwise rethrow the error, making it public.

	# Note that we are effectively inlining the command
	# "fx::mgr::config::get-global". We have to, to avoid a
	# dependency cycle.

	variable rkey
	global eval {
	    SELECT value AS location
	    FROM  global_config
	    WHERE name  = :rkey
	} {
	    if {[file pathtype $location] ne "absolute"} {
		return -code error \
		    -errorcode {FX REPOSITORY DEFAULT PATHTYPE} \
		    "Bad default repository, expected an absolute path, got $location"
	    }

	    set-repository-location $location default
	    debug.fx/fossil {done ==> default $location}
	    return $location
	}

	return {*}$o $e
    }
    sqlite3 CK $ckout

    # Retrieve repository location. This may be relative (to the
    # checkout directory).
    set location [CK onecolumn {
	SELECT value
	FROM vvar
	WHERE name = 'repository'
    }]
    debug.fx/fossil {directed to  $location}

    # Merge the path of the checkout directory and the location it
    # refered to, to resolve relative paths in the context of the
    # checkout, not the working directory. Of couse, an absolute
    # repository location supercedes the preceding path segments.
    set location [file join [file dirname $ckout] $location]
    debug.fx/fossil {resolved as  $location}

    # Normalize to make the path nicer.
    set location [file normalize $location]
    debug.fx/fossil {normalized as $location}

    CK close

    set-repository-location $location checkout
    debug.fx/fossil {done ==> checkout $location}
    return $location
}

# # ## ### ##### ######## ############# ######################

proc ::fx::fossil::has {table} {
    return [repository exists {
        SELECT name
        FROM  sqlite_master
        WHERE type = 'table'
        AND   name = :table
    }]
}

proc ::fx::fossil::global-has {table} {
    return [global exists {
        SELECT name
        FROM  sqlite_master
        WHERE type = 'table'
        AND   name = :table
    }]
}

proc ::fx::fossil::empty {table} {
    return [expr { [repository eval [subst {
        SELECT count(*) FROM "$table"
    }]] <= 0 }]
}

proc ::fx::fossil::global-empty {table} {
    return [expr { [global eval [subst {
        SELECT count(*) FROM "$table"
    }]] <= 0 }]
}

proc ::fx::fossil::fx-enum-items {table} {
    debug.fx/fossil {}
    return [repository eval [subst {
	SELECT item
	FROM   "$table"
	ORDER BY id
    }]]
}

proc ::fx::fossil::fx-enums {} {
    debug.fx/fossil {}
    set enums {}
    foreach table [fx-tables] {
	# Must match "table-of" in vt_enum.tcl.
	if {![string match fx_aku_enum_* $table]} continue
	regsub {^fx_aku_enum_} $table {} enum
	lappend enums $enum
    }
    return $enums
}

proc ::fx::fossil::fx-maps {} {
    debug.fx/fossil {}
    set maps {}
    foreach table [fx-tables] {
	# Must match "table-of" in vt_map.tcl.
	if {![string match fx_aku_map_* $table]} continue
	regsub {^fx_aku_map_} $table {} map
	lappend maps $map
    }
    return $maps
}

proc ::fx::fossil::fx-map-keys {table} {
    debug.fx/fossil {}
    return [repository eval [subst {
	SELECT key
	FROM   "$table"
	ORDER BY key
    }]]
}

proc ::fx::fossil::fx-map-get {table} {
    debug.fx/fossil {}
    return [repository eval [subst {
	SELECT key, value
	FROM   "$table"
	ORDER BY key
    }]]
}

proc ::fx::fossil::fx-tables {} {
    debug.fx/fossil {}
    set tables {}
    repository eval {
	SELECT name
	FROM sqlite_master
	WHERE type = 'table'
	AND   name LIKE 'fx_aku_%'
	;
    } {
	lappend tables [string tolower $name]
    }
    return $tables
}

proc ::fx::fossil::ticket-title {uuid} {
    debug.fx/fossil {}
    # TODO: get configured name of the title field.
    set titlefield title

    return [fossil repository onecolumn [subst {
	SELECT $titlefield
	FROM ticket
	WHERE tkt_uuid = :uuid
    }]]
}

proc ::fx::fossil::ticket-fields {} {
    debug.fx/fossil {}
    # table_info fields: cid, name, type, notnull, dflt_value, pk
    # Looking at tables "ticket" and "ticketchng".

    set columns {}
    repository eval {
	PRAGMA table_info(ticket)
    } ti {
	lappend columns $ti(name)
    }
    repository eval {
	PRAGMA table_info(ticketchng)
    } ti {
	lappend columns $ti(name)
    }

    return [lsort -unique $columns]
}

proc ::fx::fossil::exchange {url area direction} {
    debug.fx/fossil {}
    variable fossil
    variable repo_location
    # dir in (push pull sync) = exchange command.

    if {$area eq "content"} {
	exec 2>@ stderr >@ stdout \
	    {*}$fossil $direction $url -R $repo_location --once \
	    | sed -e "s|\\r|\\n|g" | sed -e {s|^|    |}
    } else {
	exec 2>@ stderr >@ stdout \
	    {*}$fossil configuration $direction $area $url -R $repo_location \
	    | sed -e "s|\\r|\\n|g" | sed -e {s|^|    |}
    }
    return
}

proc ::fx::fossil::get-manifest {uuid} {
    debug.fx/fossil {}
    variable fossil
    variable repo_location

    # We go through a temp file so that we can load the result with
    # proper binary translation. That is something 'exec' does not
    # provide for its results, that is always auto.
    #
    # We spawn the actual fossil executable to avoid having to write
    # our own implementation of the delta-decoder, and of inflate.
    #
    # FUTURE: Consider writing and using a Tcl binding to libfossil.

    set afile [pid].$uuid
    set efile [pid].error

    try {
	# There may be race conditions which cause the spawned process
	# to error with 'database locked'. If that happens we back up
	# and try again (up to 10 times). After that we throw a nice
	# error for the higher layers to handle.

	# TODO: future: make it configurable
	set trials 10
	while {[catch {
	    debug.fx/fossil {go}
	    exec > $afile 2> $efile \
		{*}$fossil artifact $uuid -R $repo_location
	} e o]} {
	    debug.fx/fossil {caught out: $e}

	    # Read the error message to see if this is about
	    # blocking. If not we throw the issue up immediately,
	    # without retrying.

	    set theerror [fileutil::cat $efile]

	    debug.fx/fossil {message.1 = [lindex [split $theerror \n] 0]}

	    if {![string match *locked* $theerror]} {
		debug.fx/fossil {rethrow}
		return {*}$o $e
	    }

	    debug.fx/fossil {locked @$trials}

	    incr trials -1
	    if {!$trials} {
		debug.fx/fossil {giving up}
		# Lock has not cleared in some time, giving up.
		return -code error \
		    -errorcode {FOSSIL PROCESS LOCKED} \
		    "artifact retrieval locked"
	    }
	    # Wait a bit first, to clear the condition.
	    # TODO: Make the delay configurable.
	    debug.fx/fossil {delay and retry}
	    after 500
	}

	set archive [fileutil::cat -translation binary -encoding binary $afile]
    } finally {
	# Ensure removal of temp files in presence of errors.
	# (Note however that this is not enough to deal with ^C).
	file delete $afile
	file delete $efile

	debug.fx/fossil {cleaned temp files}
    }

    debug.fx/fossil {done ==> <content elided>}
    return $archive
}

proc ::fx::fossil::date-of {v} {
    # sqlite timestamp (fractional julianday), convert into near-iso form.
    return [repository onecolumn {
	SELECT datetime (:v)
    }]
}

proc ::fx::fossil::branch-of {uuid} {
    debug.fx/fossil {}
    return [repository onecolumn {
	SELECT X.value
	FROM blob B, tagxref X, tag T
	WHERE B.uuid = :uuid
	AND   B.rid = X.rid
	AND   X.tagtype > 0
	AND   X.tagid = T.tagid
	AND   T.tagname = 'branch'
    }]
}

proc ::fx::fossil::last-uuid {} {
    debug.fx/fossil {}
    set uuid [repository onecolumn {
	SELECT   B.uuid
	FROM     blob  B,
	         event E
	WHERE    B.rid = E.objid
	ORDER BY E.mtime DESC
	LIMIT 1
    }]
    debug.fx/fossil {==> $uuid}
    return $uuid
}

proc ::fx::fossil::changeset {uuid} {
    debug.fx/fossil {}
    set r {}

    if {[has-ext-mlink]} {
	# An extended mlink table (having the "isaux" column) records
	# not just the changed files from the primary parent, but also
	# from any auxiliary parents (i.e. merged commits). We have to
	# exclude these records to get the proper change-set.

	repository eval {
	    SELECT filename.name AS thepath,
	    CASE WHEN nullif(mlink.pid,0) is null THEN 'added'
	    WHEN nullif(mlink.fid,0) is null THEN 'deleted'
	    ELSE                                  'edited'
	    END AS theaction
	    FROM   mlink, filename, blob
	    WHERE  mlink.mid  = blob.rid
	    AND    blob.uuid = :uuid
	    AND    mlink.fnid = filename.fnid
	    AND    NOT mlink.isaux
	    ORDER BY filename.name
	} {
	    dict lappend r $theaction $thepath
	}
    } else {
	# Regular mlink table, no extended data. Nothing to exclude.

	repository eval {
	    SELECT filename.name AS thepath,
	    CASE WHEN nullif(mlink.pid,0) is null THEN 'added'
	    WHEN nullif(mlink.fid,0) is null THEN 'deleted'
	    ELSE                                  'edited'
	    END AS theaction
	    FROM   mlink, filename, blob
	    WHERE  mlink.mid  = blob.rid
	    AND    blob.uuid = :uuid
	    AND    mlink.fnid = filename.fnid
	    ORDER BY filename.name
	} {
	    dict lappend r $theaction $thepath
	}
    }

    return $r
}

proc ::fx::fossil::reveal {value} {
    debug.fx/fossil {}
    if {$value eq {}} { return $value }
    repository eval {
	SELECT content
	FROM concealed
	WHERE hash = :value
    } {
	set value $content
    }
    return $value
}

proc ::fx::fossil::user-info {value} {
    debug.fx/fossil {}
    if {$value eq {}} { return $value }
    repository eval {
	SELECT info
	FROM user
	WHERE login = :value
    } {
	set value $info
    }
    return $value
}

proc ::fx::fossil::user-config {} {
    debug.fx/fossil {}
    return [repository eval {
	SELECT login, cap, info, mtime
	FROM user
    }]
}

proc ::fx::fossil::users {} {
    debug.fx/fossil {}
    return [repository eval {
	SELECT login
	FROM user
    }]
}

proc ::fx::fossil::schema {} {
    debug.fx/fossil {}
    return [repository one {
	SELECT value
	FROM   config
	WHERE name = 'aux-schema'
    }]
}

proc ::fx::fossil::has-ext-mlink {} {
    set result [repository one {
	SELECT 1
	FROM   sqlite_master
	WHERE  sql LIKE '%isaux%'
	AND    name = 'mlink'
    }]
    if {$result eq {}} { set result 0 }
    return $result
}

# # ## ### ##### ######## ############# ######################

proc ::fx::fossil::is {dir} {
    debug.fx/fossil {}
    foreach control {
	_FOSSIL_
	.fslckout
	.fos
    } {
	debug.fx/fossil {iterate $control}
	set control $dir/$control
	if {[file exists $control] &&
	    [file isfile $control]
	} {
	    debug.fx/fossil {done ==> HIT}
	    return 1
	}
    }
    debug.fx/fossil {done ==> MISS}
    return 0
}

proc ::fx::fossil::ckout {dir} {
    debug.fx/fossil {}
    foreach control {
	_FOSSIL_
	.fslckout
	.fos
    } {
	debug.fx/fossil {iterate $control}
	set control $dir/$control
	if {[file exists $control] &&
	    [file isfile $control]
	} {
	    debug.fx/fossil {done ==> $control}
	    return $control
	}
    }
    return -code error \
	-errorcode {FX FOSSIL CHECKOUT} \
	"Not a checkout: $dir"
}

proc ::fx::fossil::scan-up {this dir predicate} {
    debug.fx/fossil {}
    set dir [file normalize $dir]
    while {1} {
	debug.fx/fossil {iterate $dir}

	# Found the proper directory, per the predicate.
	if {[{*}$predicate $dir]} {
	    debug.fx/fossil {done ==> $dir}
	    return $dir
	}

	# Not found, walk to parent
	set new [file dirname $dir]

	# Stop when reaching the root.
	if {($new eq $dir) ||
	    ($new eq {})}   {
	    debug.fx/fossil {done ==> nothing found ($new)}
	    return {}
	}

	# Ok, truly walk up.
	set dir $new
    }
    return -code error \
	-error {FX FOSSIL SCAN-UP} \
	"$this not found"
}

# # ## ### ##### ######## ############# ######################
package provide fx::fossil 0
return
