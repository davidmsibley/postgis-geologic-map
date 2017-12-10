/*
When `map_topology.contact` table is updated, changes should propagate
to `map_topology.map_face`
*/

CREATE OR REPLACE FUNCTION map_topology.contact_geometry_changed()
RETURNS trigger AS $$
DECLARE
  CURRENT_TOPOGEOM topogeometry;
  CURRENT_TOPOLOGY text;
BEGIN

/* Set adjacent faces to dirty */

-- set the feature depending on type of operation
IF (TG_OP = 'DELETE') THEN
  CURRENT_TOPOGEOM := OLD.topo;
  CURRENT_TOPOLOGY := OLD.topology;
ELSE
  CURRENT_TOPOGEOM := NEW.topo;
  CURRENT_TOPOLOGY := NEW.topology;
END IF;

INSERT INTO map_topology.__dirty_face (id, topology)
SELECT face_id, CURRENT_TOPOLOGY
FROM map_topology.edge_face ef
WHERE ef.edge_id IN (SELECT
  (topology.GetTopoGeomElements(CURRENT_TOPOGEOM))[1])
ON CONFLICT DO NOTHING;

RETURN NULL;

END;
$$ LANGUAGE plpgsql;

/*
A materialized view to store relationships between faces,
which saves ~0.5s per query. This is updated by default
but this can be disabled for speed.
*/
DROP MATERIALIZED VIEW IF EXISTS map_topology.__face_relation;
CREATE MATERIALIZED VIEW map_topology.__face_relation AS
WITH ec AS (
SELECT
c.id contact_id,
c.topology,
(topology.GetTopoGeomElements(c.topo))[1] edge_id
FROM map_topology.contact c
)
SELECT
  f1.edge_id,
  f1.face_id f1,
  f2.face_id f2,
  ec.topology
FROM map_topology.edge_face f1
JOIN map_topology.edge_face f2
  ON f1.edge_id = f2.edge_id
 AND f1.face_id != f2.face_id
LEFT JOIN ec
  ON ec.edge_id = f1.edge_id;
-- Indexes to speed things up
CREATE INDEX map_topology__face_relation_face_index
  ON map_topology.__face_relation (f1);

CREATE OR REPLACE FUNCTION map_topology.update_map_face(
  refresh boolean DEFAULT true)
RETURNS map_topology.__dirty_face AS $$
DECLARE
  __face map_topology.__dirty_face;
  __dissolved_faces integer[];
  __deleted_face integer;
  __layer_id integer;
  __n_updated integer;
  __srid integer;
BEGIN

SELECT * INTO __face FROM map_topology.__dirty_face LIMIT 1;

SELECT srid
INTO __srid
FROM topology.topology
WHERE name='map_topology';

SELECT l.layer_id
INTO __layer_id
FROM topology.layer l
WHERE schema_name='map_topology'
AND table_name='map_face';

IF refresh THEN
  EXECUTE 'REFRESH MATERIALIZED VIEW map_topology.__face_relation';
END IF;

WITH RECURSIVE joinable_face AS (
SELECT DISTINCT ON (topology, f1, f2)
  f1, f2, topology
FROM map_topology.__face_relation
WHERE coalesce(topology,'none') != __face.topology
),
r(faces,adjacent,cycle) AS (
SELECT
  ARRAY[f.f1, f.f2] faces,
  f.f2 adjacent,
  false
FROM joinable_face f
WHERE f1 = __face.id
UNION
SELECT DISTINCT ON (f2)
  r1.faces || j.f2 faces,
  j.f2 adjacent,
  (j.f2 = ANY(r1.faces)) AS cycle
FROM joinable_face j, r r1
WHERE r1.adjacent = j.f1
  AND NOT cycle
),
faces AS (
SELECT DISTINCT unnest(faces) face FROM r
)
SELECT coalesce(array_agg(face),ARRAY[__face.id])
INTO __dissolved_faces
FROM faces;

RAISE NOTICE 'Faces: %', __dissolved_faces;

--- Update the geometry
IF (NOT 0 = ANY(__dissolved_faces)) THEN

--- Insert new topogeometry and recover ID
WITH a AS (
  SELECT ARRAY[unnest(__dissolved_faces),3]::topology.topoelement vals
),
b AS (
SELECT CreateTopoGeom('map_topology', 3, __layer_id,
  TopoElementArray_Agg(a.vals)) topo
FROM a
),
g AS (
SELECT
  topo,
  ST_SetSRID(topo::geometry,__srid) geometry,
  __face.topology
FROM b
),
ins AS (
INSERT INTO map_topology.map_face
  (unit_id, topo, topology, geometry)
SELECT
map_topology.unitForArea(g.geometry, g.topology) unit_id,
g.topo,
g.topology,
g.geometry
FROM g
RETURNING *
),
del AS (
--- Delete overlapping topogeometries and insert all of their
--- constituent faces into the dirty linework channel (if not
--- already there)
DELETE FROM map_topology.map_face mf
USING ins
WHERE ST_Overlaps(ins.geometry, mf.geometry)
RETURNING mf.id
)
SELECT id FROM del INTO __deleted_face;
/*
INSERT INTO map_topology.__dirty_face (id, topology)
SELECT
  (topology.GetTopoGeomElements(topo))[1],
  __face.topology
FROM del
ON CONFLICT DO NOTHING;
*/
END IF;

-- Delete from dirty faces where we just created a face
WITH a AS (
DELETE
FROM map_topology.__dirty_face df
WHERE topology = __face.topology
  AND id = ANY(__dissolved_faces)
RETURNING id
)
SELECT count(id)
INTO __n_updated FROM a;

RETURN __face;

END;
$$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION map_topology.update_all_map_faces()
RETURNS void AS $$
BEGIN

EXECUTE 'REFRESH MATERIALIZED VIEW map_topology.__face_relation';
-- Loop throug table of dirty linework
WHILE EXISTS (SELECT * FROM map_topology.__dirty_face)
LOOP
  PERFORM map_topology.update_map_face(false);
END LOOP;

END;
$$ LANGUAGE plpgsql;



-- Trigger to create a non-topogeometry representation for
-- storage on each row (for speed of lookup)
DROP TRIGGER IF EXISTS map_topology_contact_update_trigger ON map_topology.contact;
CREATE TRIGGER map_topology_contact_update_trigger
AFTER INSERT OR UPDATE OR DELETE ON map_topology.contact
FOR EACH ROW
EXECUTE PROCEDURE map_topology.contact_geometry_changed();

