-- SPDX-License-Identifier: GPL-2.0-or-later

CREATE OR REPLACE FUNCTION railway_api_valid_float(value TEXT) RETURNS FLOAT AS $$
BEGIN
  IF value ~ '^-?[0-9]+(\.[0-9]+)?$' THEN
    RETURN value::FLOAT;
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql
  IMMUTABLE
  LEAKPROOF
  PARALLEL SAFE;

DROP FUNCTION query_milestones(double precision, text, integer);
CREATE OR REPLACE FUNCTION query_milestones(
  input_pos double precision,
  input_ref text,
  input_limit integer
) RETURNS TABLE(
  "osm_id" bigint,
  "railway" text,
  "position" double precision,
  "latitude" double precision,
  "longitude" double precision,
  "line_ref" text,
  "milestone_ref" text,
  "operator" text,
  "wikidata" text,
  "wikimedia_commons" text,
  "image" text,
  "mapillary" text,
  "wikipedia" text,
  "note" text,
  "description" text
) AS $$
  BEGIN
    -- We do not sort the result, although we use DISTINCT ON because osm_id is sufficient to sort out duplicates
    RETURN QUERY
      SELECT
        ranked.osm_id,
        ranked.railway,
        ranked.position,
        ST_X(ranked.geom) AS latitude,
        ST_Y(ranked.geom) As longitude,
        ranked.line_ref,
        ranked.milestone_ref,
        ranked.operator,
        ranked.wikidata,
        ranked.wikimedia_commons,
        ranked.image,
        ranked.mapillary,
        ranked.wikipedia,
        ranked.note,
        ranked.description
      FROM (
        SELECT
          top_of_array.osm_id,
          top_of_array.railway,
          top_of_array.position,
          top_of_array.geom,
          top_of_array.line_ref,
          top_of_array.milestone_ref,
          top_of_array.operator,
          top_of_array.wikidata,
          top_of_array.wikimedia_commons,
          top_of_array.image,
          top_of_array.mapillary,
          top_of_array.wikipedia,
          top_of_array.note,
          top_of_array.description,
          -- We use rank(), not row_number() to get the closest and all second closest in cases like this:
          --   A B x   C
          -- where A is as far from the searched location x than C.
          rank() OVER (PARTITION BY top_of_array.operator ORDER BY top_of_array.error) AS grouped_rank
        FROM (
          SELECT
            -- Sort out duplicates which origin from tracks being split at milestones
            DISTINCT ON (unique_milestones.osm_id)
            unique_milestones.osm_id[1] AS osm_id,
            unique_milestones.railway[1] AS railway,
            unique_milestones.position,
            unique_milestones.geom[1] AS geom,
            unique_milestones.line_ref,
            unique_milestones.milestone_ref[1] AS milestone_ref,
            unique_milestones.operator,
            unique_milestones.wikidata[1] AS wikidata,
            unique_milestones.wikimedia_commons[1] AS wikimedia_commons,
            unique_milestones.image[1] AS image,
            unique_milestones.mapillary[1] AS mapillary,
            unique_milestones.wikipedia[1] AS wikipedia,
            unique_milestones.note[1] AS note,
            unique_milestones.description[1] AS description,
            unique_milestones.error
          FROM (
            SELECT
              array_agg(milestones.osm_id) AS osm_id,
              array_agg(milestones.railway) AS railway,
              milestones.position AS position,
              array_agg(milestones.geom) AS geom,
              milestones.line_ref,
              milestones.operator,
              array_agg(milestones.milestone_ref) AS milestone_ref,
              array_agg(milestones.wikidata) AS wikidata,
              array_agg(milestones.wikimedia_commons) AS wikimedia_commons,
              array_agg(milestones.image) AS image,
              array_agg(milestones.mapillary) AS mapillary,
              array_agg(milestones.wikipedia) AS wikipedia,
              array_agg(milestones.note) AS note,
              array_agg(milestones.description) AS description,
              milestones.error
            FROM (
              SELECT
                m.osm_id,
                m.railway,
                m.position,
                ST_Transform(m.geom, 4326) AS geom,
                t.ref AS line_ref,
                m.ref AS milestone_ref,
                m.wikidata,
                m.wikimedia_commons,
                m.image,
                m.mapillary,
                m.wikipedia,
                m.note,
                m.description,
                m.operator,
                ABS(input_pos - m.position) AS error
              FROM openrailwaymap_milestones AS m
              JOIN openrailwaymap_tracks_with_ref AS t
                ON t.geom && m.geom AND ST_Intersects(t.geom, m.geom) AND t.ref = input_ref
              WHERE m.position BETWEEN (input_pos - 10.0)::FLOAT AND (input_pos + 10.0)::FLOAT
              -- sort by distance from searched location, then osm_id for stable sorting
              ORDER BY error ASC, m.osm_id
            ) AS milestones
            GROUP BY milestones.position, milestones.error, milestones.line_ref, milestones.operator
          ) AS unique_milestones
        ) AS top_of_array
      ) AS ranked
      WHERE ranked.grouped_rank <= input_limit
      LIMIT input_limit;
  END
$$ LANGUAGE plpgsql
  LEAKPROOF
  PARALLEL SAFE;
