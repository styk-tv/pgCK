-- pgck 0.4.19 -> 0.4.20 — project-robust transition-map resolution (pgCK#7).
--
-- Bug (same class as #6): ckp.transition read the instance type's sealed transition map from
-- GRAPH <urn:ckp:<session-project>/kernel/ck> (session ckp.project, default 'demo'). When the
-- dispatch-session project != the kernel-load project (oci-germination#11), the applied map was
-- not found -> v_has_map=false -> fell back to the empty global config -> invalid_transition, even
-- for a transition the applied map permits.
--
-- Fix: resolve the map with GRAPH ?g — i.e. find the type's ckp:allowsTransition triples WHEREVER
-- they are sealed. ckp:allowsTransition only lives in kernel graphs (written by set_transition_map),
-- so GRAPH ?g resolves the type's map project-independently without matching non-kernel graphs.
-- Principle: a session default must not decide which kernel's rules apply to a given instance; the
-- correct map is the one sealed for the type, wherever its kernel lives. Stays pgRDF-native (the
-- map is a graph fact) — no jsonb straddle. The global-config fallback is preserved for back-compat.

CREATE OR REPLACE FUNCTION ckp.transition(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ckp, public, pg_temp
AS $trans$
DECLARE
  C        text := 'https://conceptkernel.org/ontology/v3.8/core#';
  N        text := 'https://conceptkernel.org/ontology/v3.7/';
  v_id     text := p_payload->>'id';
  v_to     text := p_payload->>'to_state';
  v_state_re text := '^[A-Za-z][A-Za-z0-9_-]*$';
  v_body   jsonb; v_from text; v_type text; v_allowed jsonb; v_has_map boolean; v_src text;
BEGIN
  IF v_to IS NULL OR v_to !~ v_state_re THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_to_state', 'to_state', v_to);
  END IF;
  SELECT body INTO v_body FROM ckp.instances WHERE id = v_id;
  IF v_body IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_instance', 'id', v_id);
  END IF;
  v_type := v_body->>'type';
  v_from := COALESCE(v_body->>(N||'lifecycle_state'), v_body->>'state', v_body->>(C||'lifecycle_state'), 'planned');

  -- T3 (v0.4.20, pgCK#7): does the instance's TYPE carry a sealed transition map in ANY kernel
  -- graph? Resolve project-independently — ckp:allowsTransition only exists in kernel graphs.
  v_has_map := (v_type IS NOT NULL AND v_type ~ '^[A-Za-z]' AND EXISTS (
    SELECT 1 FROM pgrdf.sparql(format($q$
      PREFIX ckp: <%s>
      SELECT ?t WHERE { GRAPH ?g { <%s> ckp:allowsTransition ?t } } LIMIT 1
    $q$, C, v_type)) j));

  IF v_has_map THEN
    -- the type's sealed map governs (wherever it lives). from must be a safe state to bind.
    v_src := 'kernel';
    IF v_from !~ v_state_re OR NOT EXISTS (
      SELECT 1 FROM pgrdf.sparql(format($q$
        PREFIX ckp: <%s>
        SELECT ?t WHERE { GRAPH ?g {
          <%s> ckp:allowsTransition ?t . ?t ckp:fromState "%s" ; ckp:toState "%s" } }
      $q$, C, v_type, v_from, v_to)) j) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_transition',
                                'from', v_from, 'to', v_to, 'source', v_src);
    END IF;
  ELSE
    -- fallback: the global config map (back-compat).
    v_src := 'config';
    v_allowed := (SELECT v::jsonb FROM ckp.config WHERE k='transition_map')->v_from;
    IF v_allowed IS NULL OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_allowed) e WHERE e = v_to) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_transition',
                                'from', v_from, 'to', v_to, 'allowed', v_allowed, 'source', v_src);
    END IF;
  END IF;

  v_body := v_body || jsonb_build_object(N||'lifecycle_state', v_to, 'state', v_to);
  PERFORM ckp.seal(v_id, v_body);
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'from', v_from, 'to', v_to,
                            'source', v_src, 'verified', ckp.verify(v_id));
END;
$trans$;
ALTER FUNCTION ckp.transition(jsonb) OWNER TO ck_substrate;
