#!/usr/bin/env perl

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use MusicBrainz::Server::Context;
use MusicBrainz::Server::Constants qw( %ENTITIES entities_with $MAX_INITIAL_MEDIUMS );
use MusicBrainz::Server::Data::Relationship;
use DBDefs;
use Sql;
use Getopt::Long;
use URI::Escape qw( uri_escape_utf8 );
use Try::Tiny;

use WWW::SitemapIndex::XML;
use WWW::Sitemap::XML;
use DateTime;
use List::Util qw( min );
use List::MoreUtils qw( natatime );
use List::UtilsBy qw( sort_by );
use File::Slurp qw( read_dir );
use Digest::MD5 qw( md5_hex );
use Readonly;
use POSIX;
use DateTime::Format::Pg;

# Constants
Readonly my $EMPTY_PAGE_PRIORITY => 0.1;
Readonly my $SECONDARY_PAGE_PRIORITY => 0.3;
Readonly my $DEFAULT_PAGE_PRIORITY => 0.5;
Readonly my $MAX_SITEMAP_SIZE => 50000.0;

# Check options

my $web_server = DBDefs->CANONICAL_SERVER;
my $fHelp;
my $fCompress = 1;
my $fPing = 0;

GetOptions(
    "help"                        => \$fHelp,
    "compress|c!"                 => \$fCompress,
    "ping|p"                      => \$fPing,
    "web-server=s"                => \$web_server,
) or exit 2;

=head1 SYNOPSIS

admin/BuildSitemaps.pl: build XML sitemaps/sitemap-indexes to a standard location.

Options:

    --help             show this help
    --compress/-c      compress (default true)
    --ping/-p          ping search engines once built
    --web-server       provide a web server as the base to use in sitemap-index
                       files (without trailing slash).
                       Defaults to DBDefs->CANONICAL_SERVER
=cut

sub usage {
    print <<EOF;
Usage: BuildSitemaps.pl [options]

    --help             show this help
    --compress/-c      compress (default true)
    --ping/-p          ping search engines once built
    --web-server       provide a web server as the base to use in sitemap-index
                       files (without trailing slash).
                       Defaults to DBDefs->CANONICAL_SERVER
EOF
}

usage(), exit if $fHelp;

=head1 DESCRIPTION

=over

=item 1.

First, creates a context C<$c> to use, especially its Sql object (C<$sql>).

=cut

my $c = MusicBrainz::Server::Context->create_script_context;
my $sql = Sql->new($c->conn);

print localtime() . " Building sitemaps and sitemap index files\n";

=pod

=item 2.

Set up a sitemap index object C<$index>.

=cut

my $index_filename = "sitemap-index.xml";
$index_filename .= '.gz' if $fCompress;
my $index_localname = "$FindBin::Bin/../root/static/sitemaps/$index_filename";

my $index = WWW::SitemapIndex::XML->new();

=pod

=item 3.

Create a (global) variable C<@sitemap_files> to store the list of sitemap files in;
this is used to determine which files to delete during cleanup

=cut
my @sitemap_files;

=pod

=item 4.

Load old index (if present) to keep track of the modification times of
sitemaps, in case they're unchanged.

=cut

my %old_sitemap_modtime;
if (-f $index_localname) {
    my $old_index = WWW::SitemapIndex::XML->new();
    $old_index->load( location => $index_localname );
    %old_sitemap_modtime = map { $_->loc => $_->lastmod } grep { $_->loc && $_->lastmod } $old_index->sitemaps;
}

=pod

=item 5.

Build sitemaps by looping over each entity type that's applicable and calling
C<build_one_entity>. Runs in one repeatable-read transaction for data consistency.

Temporary tables are created and filled first.

=cut

drop_temporary_tables($sql); # Drop first, just in case.
create_temporary_tables($sql);
$sql->begin;
$sql->do("SET TRANSACTION READ ONLY, ISOLATION LEVEL REPEATABLE READ");
fill_temporary_tables($sql);
for my $entity_type (entities_with(['mbid', 'indexable']), 'cdtoc') {
    build_one_entity($entity_type, $index, $sql);
}
$sql->commit;
drop_temporary_tables($sql);

=pod

=item 6.

Once all sitemaps are built, use C<$index> to write a sitemap index file.

=cut

$index->write($index_localname);
push @sitemap_files, $index_filename;

# This needs adding or it'll get deleted every time
push @sitemap_files, '.gitkeep';

=pod

=item 7.

Then, remove any file that wasn't just built, to remove outdated files.

=cut

print localtime() . " Built index $index_filename, deleting outdated files\n";
my @files = read_dir("$FindBin::Bin/../root/static/sitemaps");
for my $file (@files) {
    if (!grep { $_ eq $file } @sitemap_files) {
        print localtime() . " removing $file\n";
        unlink "$FindBin::Bin/../root/static/sitemaps/$file";
    }
}

=pod

=item 8.

Finally, ping search engines (if the option is turned on) and finish.

=back

=cut

# Ping search engines, if applicable
if ($fPing) {
    print localtime() . " Pinging search engines\n";
    ping_search_engines($c, "$web_server/$index_filename");
}

print localtime() . " Done\n";

# --------------- END MAIN BODY ---------------

=head1 FUNCTIONS

=head2 create_temporary_tables, fill_temporary_tables, drop_temporary_tables

These functions create, fill with data, and drop, respectively, the temporary
tables used to assist in the process of creating sitemaps.

=cut

sub create_temporary_tables {
    my ($sql) = @_;
    $sql->begin;
    $sql->do(
        "CREATE TEMPORARY TABLE tmp_sitemaps_artist_direct_rgs
             (artist INTEGER,
              rg     INTEGER,
              is_official BOOLEAN NOT NULL,

              PRIMARY KEY (artist, rg))
         ON COMMIT DELETE ROWS");
    $sql->do(
        "CREATE TEMPORARY TABLE tmp_sitemaps_artist_va_rgs
             (artist INTEGER,
              rg     INTEGER,
              is_official BOOLEAN NOT NULL,

              PRIMARY KEY (artist, rg))
         ON COMMIT DELETE ROWS");
    $sql->do(
        "CREATE TEMPORARY TABLE tmp_sitemaps_artist_direct_releases
             (artist  INTEGER,
              release INTEGER,

              PRIMARY KEY (artist, release))
         ON COMMIT DELETE ROWS");
    $sql->do(
        "CREATE TEMPORARY TABLE tmp_sitemaps_artist_va_releases
             (artist  INTEGER,
              release INTEGER,

              PRIMARY KEY (artist, release))
         ON COMMIT DELETE ROWS");
    $sql->do(
        "CREATE TEMPORARY TABLE tmp_sitemaps_artist_recordings
             (artist        INTEGER,
              recording     INTEGER,
              is_video      BOOLEAN NOT NULL,
              is_standalone BOOLEAN NOT NULL,

              PRIMARY KEY (artist, recording))
         ON COMMIT DELETE ROWS");
    $sql->do(
        "CREATE TEMPORARY TABLE tmp_sitemaps_artist_works
             (artist   INTEGER,
              work     INTEGER,

              PRIMARY KEY (artist, work))
         ON COMMIT DELETE ROWS");

    $sql->do(
         "CREATE TEMPORARY TABLE tmp_sitemaps_instrument_recordings
             (instrument INTEGER,
              recording  INTEGER,

              PRIMARY KEY (instrument, recording))
          ON COMMIT DELETE ROWS");
    $sql->do(
         "CREATE TEMPORARY TABLE tmp_sitemaps_instrument_releases
             (instrument INTEGER,
              release  INTEGER,

              PRIMARY KEY (instrument, release))
          ON COMMIT DELETE ROWS");
    $sql->commit;
}

sub fill_temporary_tables {
    my ($sql) = @_;
    my $is_official = "(EXISTS (SELECT TRUE FROM release where release.release_group = q.rg AND release.status = '1')
                        OR NOT EXISTS (SELECT 1 FROM release WHERE release.release_group = q.rg AND release.status IS NOT NULL))";

    # Release groups that will appear on the non-VA listings, per artist
    $sql->do("INSERT INTO tmp_sitemaps_artist_direct_rgs (artist, rg, is_official)
                  SELECT artist, rg, $is_official FROM
                  (SELECT DISTINCT artist_credit_name.artist AS artist, release_group.id AS rg
                    FROM release_group
                    JOIN artist_credit_name ON release_group.artist_credit = artist_credit_name.artist_credit) q");
    $sql->do("ANALYZE tmp_sitemaps_artist_direct_rgs");
    # Release groups that will appear on the VA listings, per artist. Uses the above temporary table to exclude non-VA appearances.
    $sql->do("INSERT INTO tmp_sitemaps_artist_va_rgs (artist, rg, is_official)
                  SELECT artist, rg, $is_official FROM
                  (SELECT DISTINCT artist_credit_name.artist AS artist, release_group.id AS rg
                    FROM release_group
                    JOIN release ON release.release_group = release_group.id
                    JOIN medium ON medium.release = release.id
                    JOIN track ON track.medium = medium.id
                    JOIN artist_credit_name ON track.artist_credit = artist_credit_name.artist_credit
                   WHERE NOT EXISTS (SELECT TRUE FROM tmp_sitemaps_artist_direct_rgs WHERE artist = artist_credit_name.artist AND rg = release_group.id)) q");
    $sql->do("ANALYZE tmp_sitemaps_artist_va_rgs");

    # Releases that will appear in the non-VA part of the artist releases tab, per artist
    $sql->do("INSERT INTO tmp_sitemaps_artist_direct_releases (artist, release)
                  SELECT DISTINCT artist_credit_name.artist AS artist, release.id AS release
                    FROM release JOIN artist_credit_name ON release.artist_credit = artist_credit_name.artist_credit");
    $sql->do("ANALYZE tmp_sitemaps_artist_direct_releases");
    # Releases that will appear in the VA listings instead. Uses above table to exclude non-VA appearances.
    $sql->do("INSERT INTO tmp_sitemaps_artist_va_releases (artist, release)
                  SELECT DISTINCT artist_credit_name.artist AS artist, release.id AS release
                    FROM release
                    JOIN medium ON medium.release = release.id
                    JOIN track ON track.medium = medium.id
                    JOIN artist_credit_name ON track.artist_credit = artist_credit_name.artist_credit
                   WHERE NOT EXISTS (SELECT TRUE FROM tmp_sitemaps_artist_direct_releases WHERE artist = artist_credit_name.artist AND release = release.id)");
    $sql->do("ANALYZE tmp_sitemaps_artist_va_releases");

    $sql->do("INSERT INTO tmp_sitemaps_artist_recordings (artist, recording, is_video, is_standalone)
                  WITH track_recordings (recording) AS (
                      SELECT DISTINCT recording FROM track
                  )
                  SELECT DISTINCT ON (artist, recording)
                      artist_credit_name.artist AS artist, recording.id as recording,
                      video as is_video, track_recordings.recording IS NULL AS is_standalone
                    FROM recording
                    JOIN artist_credit_name ON recording.artist_credit = artist_credit_name.artist_credit
                    LEFT JOIN track_recordings ON recording.id = track_recordings.recording");
    $sql->do("ANALYZE tmp_sitemaps_artist_recordings");

    # Works linked directly to artists as well as via recording ACs.
    $sql->do("INSERT INTO tmp_sitemaps_artist_works (artist, work)
                  SELECT entity0 AS artist, entity1 AS work from l_artist_work
                   UNION DISTINCT
                  SELECT tsar.artist AS artist, entity1 AS work
                    FROM tmp_sitemaps_artist_recordings tsar
                    JOIN l_recording_work ON tsar.recording = l_recording_work.entity0");
    $sql->do("ANALYZE tmp_sitemaps_artist_works");

    # Instruments linked to recordings via artist-recording relationship
    # attributes. Matches Data::Recording, which also ignores other tables
    $sql->do("INSERT INTO tmp_sitemaps_instrument_recordings (instrument, recording)
                  SELECT DISTINCT instrument.id AS instrument, l_artist_recording.entity1 AS recording
                    FROM instrument
                    JOIN link_attribute_type ON link_attribute_type.gid = instrument.gid
                    JOIN link_attribute ON link_attribute.attribute_type = link_attribute_type.id
                    JOIN l_artist_recording ON l_artist_recording.link = link_attribute.link");
    $sql->do("ANALYZE tmp_sitemaps_instrument_recordings");

    # Instruments linked to releases via artist-release relationship
    # attributes. Matches Data::Release, which also ignores other tables
    $sql->do("INSERT INTO tmp_sitemaps_instrument_releases (instrument, release)
                  SELECT DISTINCT instrument.id AS instrument, l_artist_release.entity1 AS release
                    FROM instrument
                    JOIN link_attribute_type ON link_attribute_type.gid = instrument.gid
                    JOIN link_attribute ON link_attribute.attribute_type = link_attribute_type.id
                    JOIN l_artist_release ON l_artist_release.link = link_attribute.link");
    $sql->do("ANALYZE tmp_sitemaps_instrument_releases");
}

sub drop_temporary_tables {
    my ($sql) = @_;
    $sql->begin;
    for my $table (qw( artist_direct_rgs
                       artist_va_rgs
                       artist_direct_releases
                       artist_va_releases
                       artist_recordings
                       artist_works
                       instrument_recordings
                       instrument_releases )) {
        $sql->do("DROP TABLE IF EXISTS tmp_sitemaps_$table");
    }
    $sql->commit;
}

=head2 build_one_entity

The "main loop" function. Takes an entity type, figures out batches to build
and what to build for each batch, then calls out to do it.

=cut

sub build_one_entity {
    my ($entity_type, $index, $sql) = @_;

    # Find the counts in each potential batch of 50,000
    my $raw_batches = $sql->select_list_of_hashes(
        "SELECT batch, count(id) from (SELECT id, ceil(id / ?::float) AS batch FROM $entity_type) q GROUP BY batch ORDER BY batch ASC",
        $MAX_SITEMAP_SIZE
    );
    my @batches;

    # Exclude the last batch, which should always be its own sitemap.
    if (scalar @$raw_batches > 1) {
        my $batch = {count => 0, batches => []};
        for my $raw_batch (@{ $raw_batches }[0..scalar @$raw_batches-2]) {
            # Add this potential batch to the previous one if the sum will come out less than 50,000
            # Otherwise create a new batch and push the previous one onto the list.
            if ($batch->{count} + $raw_batch->{count} <= $MAX_SITEMAP_SIZE) {
                $batch->{count} = $batch->{count} + $raw_batch->{count};
                push @{$batch->{batches}}, $raw_batch->{batch};
            } else {
                push @batches, $batch;
                $batch = {count => $raw_batch->{count}, batches => [$raw_batch->{batch}]};
            }
        }
        push @batches, $batch;
    }

    # Add last batch.
    my $last_batch = $raw_batches->[scalar @$raw_batches - 1];
    push @batches, {count =>   $last_batch->{count},
                    batches => [$last_batch->{batch}]};

    my $suffix_info = build_suffix_info($entity_type);

    for my $batch_info (@batches) {
        build_one_batch($entity_type, $batch_info, $suffix_info, $index, $sql);
    }
}

=head2 build_suffix_info

Given an entity type, build information about URL suffixes and their associated
SQL and priorities.

=cut

sub build_suffix_info {
    my ($entity_type) = @_;

    my $priority_by_count = sub {
        my ($count_prop) = @_;
        return sub {
            my (%opts) = @_;
            return $SECONDARY_PAGE_PRIORITY if $opts{$count_prop} > 0;
            return $EMPTY_PAGE_PRIORITY;
        }
    };

    my $entity_properties = $ENTITIES{$entity_type} // {};
    my $suffix_info = {base => {
    }};
    if ($entity_type eq 'artist') {
        $suffix_info->{base}{extra_sql} = {
            columns => "(SELECT count(rg) FROM tmp_sitemaps_artist_direct_rgs tsadr WHERE tsadr.artist = artist.id AND is_official) official_rg_count",
        };
        $suffix_info->{base}{paginated} = "official_rg_count";
        $suffix_info->{all} = {
            extra_sql => {columns => "(SELECT count(rg) FROM tmp_sitemaps_artist_direct_rgs tsadr WHERE tsadr.artist = artist.id) all_rg_count"},
            paginated => "all_rg_count",
            suffix => 'all=1',
            filename_suffix => 'all',
            suffix_delimiter => '?'
        };
        $suffix_info->{va} = {
            extra_sql => {columns => "(SELECT count(rg) FROM tmp_sitemaps_artist_va_rgs tsavr WHERE tsavr.artist = artist.id AND is_official) official_va_rg_count"},
            paginated => "official_va_rg_count",
            suffix => 'va=1',
            filename_suffix => 'va',
            suffix_delimiter => '?',
            priority => $priority_by_count->('official_va_rg_count')
        };
        $suffix_info->{all_va} = {
            extra_sql => {columns => "(SELECT count(rg) FROM tmp_sitemaps_artist_va_rgs tsavr WHERE tsavr.artist = artist.id) all_va_rg_count"},
            paginated => "all_va_rg_count",
            suffix => 'va=1&all=1',
            filename_suffix => 'va-all',
            suffix_delimiter => '?',
            priority => $priority_by_count->('all_va_rg_count')
        };
        $suffix_info->{releases} = {
            extra_sql => {columns => "(SELECT count(release) FROM tmp_sitemaps_artist_direct_releases tsadre WHERE tsadre.artist = artist.id) direct_release_count"},
            paginated => "direct_release_count",
            suffix => 'releases',
            priority => $priority_by_count->('direct_release_count')
        };
        $suffix_info->{releases_va} = {
            extra_sql => {columns => "(SELECT count(release) FROM tmp_sitemaps_artist_va_releases tsavre WHERE tsavre.artist = artist.id) va_release_count"},
            paginated => "va_release_count",
            suffix => 'releases?va=1',
            filename_suffix => 'releases-va',
            priority => $priority_by_count->('va_release_count')
        };
        $suffix_info->{recordings} = {
            extra_sql => {columns => "(SELECT count(recording) FROM tmp_sitemaps_artist_recordings tsar WHERE tsar.artist = artist.id) recording_count"},
            paginated => "recording_count",
            suffix => 'recordings',
            priority => $priority_by_count->('recording_count')
        };
        $suffix_info->{recordings_video} = {
            extra_sql => {columns => "(SELECT count(recording) FROM tmp_sitemaps_artist_recordings tsar WHERE tsar.artist = artist.id AND is_video) video_count"},
            paginated => "video_count",
            suffix => 'recordings?video=1',
            filename_suffix => 'recordings-video',
            priority => $priority_by_count->('video_count')
        };
        $suffix_info->{recordings_standalone} = {
            extra_sql => {columns => "(SELECT count(recording) FROM tmp_sitemaps_artist_recordings tsar WHERE tsar.artist = artist.id AND is_standalone) standalone_count"},
            paginated => "standalone_count",
            suffix => 'recordings?standalone=1',
            filename_suffix => 'recordings-standalone',
            priority => $priority_by_count->('standalone_count')
        };
        $suffix_info->{works} = {
            extra_sql => {columns => "(SELECT count(work) FROM tmp_sitemaps_artist_works tsaw WHERE tsaw.artist = artist.id) work_count"},
            paginated => "work_count",
            suffix => 'works',
            priority => $priority_by_count->('work_count')
        };
        $suffix_info->{events} = {
            # NOTE: no temporary table needed, since this can really probably just hit l_artist_event directly, no need to join or union. Can revisit if performance is an issue.
            extra_sql => {columns => "(SELECT count(DISTINCT entity1) FROM l_artist_event WHERE entity0 = artist.id) event_count"},
            paginated => "event_count",
            suffix => 'events',
            priority => $priority_by_count->('event_count')
        };
    }

    if ($entity_type eq 'instrument') {
        $suffix_info->{recordings} = {
            extra_sql => {columns => "(SELECT count(recording) FROM tmp_sitemaps_instrument_recordings tsir where tsir.instrument = instrument.id) recording_count"},
            paginated => "recording_count",
            suffix => 'recordings',
            priority => $priority_by_count->('recording_count')
        };
        $suffix_info->{releases} = {
            extra_sql => {columns => "(SELECT count(release) FROM tmp_sitemaps_instrument_releases tsir where tsir.instrument = instrument.id) release_count"},
            paginated => "release_count",
            suffix => 'releases',
            priority => $priority_by_count->('release_count')
        };
    }

    if ($entity_type eq 'label') {
        $suffix_info->{base}{extra_sql} = {
            columns => "(SELECT count(DISTINCT release) FROM release_label WHERE release_label.label = label.id) release_count"
        };
        $suffix_info->{base}{paginated} = "release_count";
    }

    if ($entity_type eq 'place') {
        $suffix_info->{events} = {
            # NOTE: no temporary table needed, since this can really probably just hit l_event_place directly, no need to join or union. Can revisit if performance is an issue.
            extra_sql => {columns => "(SELECT count(DISTINCT entity0) FROM l_event_place WHERE entity1 = place.id) event_count"},
            paginated => "event_count",
            suffix => 'events',
            priority => $priority_by_count->('event_count')
        };
    }

    if ($entity_type eq 'release') {
        $suffix_info->{'cover-art'} = {
            suffix => 'cover-art',
            priority => sub {
                my (%opts) = @_;
                return $SECONDARY_PAGE_PRIORITY if $opts{cover_art_presence} eq 'present';
                return $EMPTY_PAGE_PRIORITY;
            },
            extra_sql => {join => 'release_meta ON release.id = release_meta.id',
                          columns => 'cover_art_presence'}
        };

        $suffix_info->{'disc'} = {
            extra_sql => {columns => "(SELECT count(DISTINCT id) FROM medium WHERE medium.release = release.id) AS medium_count"},
            filename_suffix => 'disc',
            url_constructor => sub {
                my ($ids, $create_opts, $entity_url, %opts) = @_;
                my @paginated_urls;
                for my $id_info (@$ids) {
                    if ($id_info->{medium_count} > $MAX_INITIAL_MEDIUMS) {
                        my $id = $id_info->{main_id};
                        my $url_base = $web_server . '/' . $entity_url . '/' . $id;
                        for (my $i = 1; $i < $id_info->{medium_count} + 1; $i++) {
                            push(@paginated_urls, $create_opts->("$url_base/disc/$i", $id_info));
                        }
                    }
                }
                return {base => [], paginated => \@paginated_urls}
            }
        }
    }

    if ($entity_type eq 'release_group') {
        $suffix_info->{base}{extra_sql} = {
            columns => "(SELECT count(DISTINCT release.id) FROM release WHERE release.release_group = release_group.id) release_count"
        };
        $suffix_info->{base}{paginated} = "release_count";
    }

    if ($entity_properties->{aliases}) {
        $suffix_info->{aliases} = {
            suffix => 'aliases',
            priority => sub {
                my (%opts) = @_;
                return $SECONDARY_PAGE_PRIORITY if $opts{has_aliases};
                return $EMPTY_PAGE_PRIORITY;
            },
            extra_sql => {columns => "EXISTS (SELECT true FROM ${entity_type}_alias a WHERE a.$entity_type = ${entity_type}.id) AS has_aliases"}
        };
    }
    if ($entity_properties->{mbid}{indexable}) {
        # These pages are nearly worthless, so can really just be ignored.
        $suffix_info->{details} = {
            suffix => 'details',
            priority => $EMPTY_PAGE_PRIORITY
        };
    }
    if ($entity_properties->{mbid}{relatable} eq 'dedicated') {
        my @tables = MusicBrainz::Server::Data::Relationship::_generate_table_list($entity_type, grep { $_ ne 'url' } entities_with(['mbid','relatable']));
        my $select = join(' UNION ALL ', map { 'SELECT TRUE FROM ' . $_->[0] . ' WHERE ' . $_->[1] . " = ${entity_type}.id" } @tables);
        $suffix_info->{relationships} = {
            suffix => 'relationships',
            priority => sub {
                my (%opts) = @_;
                return $SECONDARY_PAGE_PRIORITY if $opts{has_non_url_rels};
                return $EMPTY_PAGE_PRIORITY;
            },
            extra_sql => {columns => "EXISTS ($select) AS has_non_url_rels"}
        };
    }
    if ($entity_properties->{custom_tabs}) {
        my %tabs = map { $_ => 1 } @{ $entity_properties->{custom_tabs} };
        for my $tab (qw( events releases recordings works performances map discids )) {
            # XXX: discids, performances should have extra sql for priority
            # XXX: pagination, priority based on counts for paginated things
            if ($tabs{$tab} && !$suffix_info->{$tab}) {
                $suffix_info->{$tab} = {
                    suffix => $tab,
                    priority => sub { return $SECONDARY_PAGE_PRIORITY }
                };
            }
        }
    }
    return $suffix_info;
}

=head2 build_one_batch

Called by C<build_one_entity> for a given batch. Fetches the set of base URLs
and then builds the main sitemaps and any suffix sitemaps.

=cut

sub build_one_batch {
    my ($entity_type, $batch_info, $suffix_info, $index, $sql) = @_;

    my $minimum_batch_number = min(@{ $batch_info->{batches} });
    my $entity_id = $entity_type eq 'cdtoc' ? 'discid' : 'gid';
    my $entity_properties = $ENTITIES{$entity_type} // {};

    # Merge the extra joins/columns needed for particular suffixes
    my %extra_sql = (join => '', columns => []);
    for my $suffix (keys %$suffix_info) {
        my %extra = %{$suffix_info->{$suffix}{extra_sql} // {}};
        if ($extra{columns}) {
            push(@{ $extra_sql{columns} }, $extra{columns});
        }
        if ($extra{join}) {
            $extra_sql{join} .= " JOIN $extra{join}";
        }
    }
    my $columns = join(', ', "$entity_id AS main_id", @{ $extra_sql{columns} });
    my $tables = $entity_type . $extra_sql{join};

    if ($entity_properties->{lastmod_table}) {
        $tables .= " LEFT JOIN ${entity_type}_lastmod lastmod ON ($entity_type.id = lastmod.id)";
        $columns .= ", lastmod.last_modified AS lastmod";
    }

    my $query = "SELECT $columns FROM $tables " .
                "WHERE ceil(${entity_type}.id / ?::float) = any(?) " .
                "ORDER BY ${entity_type}.id ASC";
    my $ids = $sql->select_list_of_hashes($query, $MAX_SITEMAP_SIZE, $batch_info->{batches});

    for my $suffix (keys %$suffix_info) {
        my %opts = %{ $suffix_info->{$suffix} // {}};
        build_one_suffix($entity_type, $minimum_batch_number, $index, $ids, %opts);
    }
}

=head2 build_one_suffix

Called by C<build_one_batch> to build an individual suffix's sitemaps given the
necessary information to build the sitemap.

=cut

sub build_one_suffix {
    my ($entity_type, $minimum_batch_number, $index, $ids, %opts) = @_;
    my $entity_properties = $ENTITIES{$entity_type} // {};
    my $entity_url = $entity_properties->{url} || $entity_type;

    my $base_filename = "sitemap-$entity_type-$minimum_batch_number";
    if ($opts{suffix} || $opts{filename_suffix}) {
        my $filename_suffix = $opts{filename_suffix} // $opts{suffix};
        $base_filename .= "-$filename_suffix";
    }
    my $ext = $fCompress ? '.xml.gz' : '.xml';

    my $create_opts = sub {
        my ($url, $id_info) = @_;

        # Default priority is 0.5, per spec.
        my %add_opts = (loc => $url);
        if ($opts{priority}) {
            $add_opts{priority} = ref $opts{priority} eq 'CODE' ? $opts{priority}->(%$id_info) : $opts{priority};
        }
        if ($entity_properties->{lastmod_table} && $id_info->{lastmod}) {
            $add_opts{lastmod} = DateTime::Format::Pg->parse_datetime($id_info->{lastmod});
        }
        return \%add_opts;
    };

    my $construct_url_lists = sub {
        my ($ids, $create_opts, $entity_url, %opts) = @_;
        my @base_urls;
        my @paginated_urls;

        for my $id_info (@$ids) {
            my $id = $id_info->{main_id};
            my $url = $web_server . '/' . $entity_url . '/' . $id;
            if ($opts{suffix}) {
                my $suffix_delimiter = $opts{suffix_delimiter} // '/';
                $url .= "$suffix_delimiter$opts{suffix}";
            }
            push(@base_urls, $create_opts->($url, $id_info));

            if ($opts{paginated}) {
                # 50 items per page, and the first page is covered by the base.
                my $paginated_count = ceil($id_info->{$opts{paginated}} / 50) - 1;

                # Since we exclude page 1 above, this is for anything above 0.
                if ($paginated_count > 0) {
                    # Start from page 2, and add one to the count for the last page
                    # (since the count was one less due to the exclusion of the first
                    # page)
                    my $use_amp = $url =~ m/\?/;
                    my @new_paginated_urls = map { $url . ($use_amp ? '&' : '?') . "page=$_" } (2..$paginated_count+1);

                    # Expand these all to full specifications for build_one_sitemap.
                    push(@paginated_urls, map { $create_opts->($_, $id_info) } @new_paginated_urls);
                }
            }
        }

        return {base => \@base_urls, paginated => \@paginated_urls}
    };

    my $url_constructor = $opts{url_constructor} // $construct_url_lists;
    my $urls = $url_constructor->($ids, $create_opts, $entity_url, %opts);
    my @base_urls = @{ $urls->{base} };
    my @paginated_urls = @{ $urls->{paginated} };

    # If we can fit all the paginated stuff into the main sitemap file, why not do it?
    if (@paginated_urls && scalar @base_urls + scalar @paginated_urls <= $MAX_SITEMAP_SIZE) {
        print localtime() . " paginated plus base urls are fewer than 50k for $base_filename, combining into one...\n";
        push(@base_urls, @paginated_urls);
        @paginated_urls = ();
    }

    my $filename = $base_filename . $ext;
    if (@base_urls) {
        build_one_sitemap($filename, $index, @base_urls);
    }

    if (@paginated_urls) {
        my $iter = natatime $MAX_SITEMAP_SIZE, @paginated_urls;
        my $page_number = 1;
        while (my @urls = $iter->()) {
            my $paginated_filename = $base_filename . "-$page_number" . $ext;
            build_one_sitemap($paginated_filename, $index, @urls);
            $page_number++;
        }
    }
}

=head2 build_one_sitemap

Called by C<build_one_suffix> to build an individual sitemap given a filename,
the sitemap index object, and the list of URLs with appropriate options.

=cut

sub build_one_sitemap {
    my ($filename, $index, @urls) = @_;

    die "Too many URLs for one sitemap: $filename" if scalar @urls > $MAX_SITEMAP_SIZE;

    my $local_filename = "$FindBin::Bin/../root/static/sitemaps/$filename";
    my $remote_filename = $web_server . '/' . $filename;
    my $existing_md5;

    if (-f $local_filename) {
        $existing_md5 = hash_sitemap($local_filename);
    }
    local $| = 1; # autoflush stdout
    print localtime() . " Building $filename...";
    my $map = WWW::Sitemap::XML->new();
    for my $url (@urls) {
        $map->add(%$url);
    }
    $map->write($local_filename);
    push @sitemap_files, $filename;

    my $modtime = DateTime->now->date(); # YYYY-MM-DD
    if ($existing_md5 && $existing_md5 eq hash_sitemap($map) && $old_sitemap_modtime{$remote_filename}) {
        print "using previous modtime, since file unchanged...";
        $modtime = $old_sitemap_modtime{$remote_filename};
    }

    $index->add(loc => $remote_filename, lastmod => $modtime);
    print " built.\n";
}

=head2 ping_search_engines

Use the context's LWP to ping each appropriate search engine URL, given the
remove URL of the sitemap index.

=cut

sub ping_search_engines {
    my ($c, $url) = @_;

    my @sitemap_prefixes = ('http://www.google.com/webmasters/tools/ping?sitemap=', 'http://www.bing.com/webmaster/ping.aspx?siteMap=');
    for my $prefix (@sitemap_prefixes) {
        try {
            my $ping_url = $prefix . uri_escape_utf8($url);
            $c->lwp->get($ping_url);
        } catch {
            print "Failed to ping $prefix.\n";
        }
    }
}

=head2 hash_sitemap

Used by C<build_one_suffix> to determine if a sitemap has changed since the
previous build, for insertion to the sitemap index, by sorting consistenly,
joining together applicable properties, and md5ing the URL contents of a
sitemap. It's passed either a filename or an already-initialized C<$map>
object.

=cut

sub hash_sitemap {
    my ($filename_or_map) = @_;
    my $map;
    if (ref($filename_or_map) eq '') {
        $map = WWW::Sitemap::XML->new();
        $map->load( location => $filename_or_map );
    } else {
        $map = $filename_or_map;
    }
    return md5_hex(join('|', map { join(',', $_->loc, $_->lastmod // '', $_->changefreq // '', $_->priority // '') } sort_by { $_->loc } $map->urls));
}

=head1 COPYRIGHT

Copyright (C) 2014 MetaBrainz Foundation

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.

=cut
