SET session_replication_role = replica;

UPDATE map_digitizer.linework
SET
  topo = null,
  geometry_hash = null,
  topology_error = null;

TRUNCATE TABLE map_topology.face CASCADE;
TRUNCATE TABLE map_topology.relation CASCADE;
TRUNCATE TABLE map_topology.map_face CASCADE;

INSERT INTO map_topology.face (face_id) VALUES (0);

ALTER SEQUENCE map_topology.node_node_id_seq RESTART WITH 1;
ALTER SEQUENCE map_topology.face_face_id_seq RESTART WITH 1;
ALTER SEQUENCE map_topology.edge_data_edge_id_seq RESTART WITH 1;
ALTER SEQUENCE map_topology.topogeo_s_1 RESTART WITH 1;

SELECT setval(pg_get_serial_sequence('map_topology.map_face', 'id'), coalesce(max(id),0)+1, false)
  FROM map_topology.map_face;
SET session_replication_role = DEFAULT;
VACUUM ANALYZE;
