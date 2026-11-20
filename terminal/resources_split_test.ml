open! Core
open Hardcaml_workbench_protocol
module P = Hardcaml_workbench_workspaces
module H = Workspace_host
module W = Workspace

let%test_unit "mouse-selected list row drives linked detail; scrolling cannot move the \
               list"
  =
  let host, data, find =
    Host_view.refinement_fixture (Option.value_exn (P.Presets.find "resources"))
  in
  let resources, asic = Resources_view_test.imported () in
  let list = find "resources"
  and reader = find "resource-detail" in
  let data = { data with asic } in
  let host = H.set_local host list.id { (H.local host list.id) with resources } in
  let page host tile = Host_view.resource_page host data tile ~width:60 ~height:32 in
  let row, _ =
    List.findi_exn (page host list) ~f:(fun _ -> function
      | Some (`Resource "data"), _ -> true
      | _ -> false)
  in
  let host = Host_view.select_body_row host data list ~width:60 ~height:32 ~row in
  let owner = H.local host list.id in
  assert (Option.equal String.equal owner.resources.selected (Some "data"));
  assert (Option.is_none owner.resources.pending);
  assert (
    List.exists (page host reader) ~f:(fun (_, spans) ->
      let line = Evidence_style.text spans in
      String.is_prefix line ~prefix:"Resource:" && String.is_suffix line ~suffix:"data"));
  let list_text host =
    List.map (page host list) ~f:(fun (_, spans) -> Evidence_style.text spans)
  in
  let before = list_text host in
  let host, _, operation =
    H.route_resource_input host reader ~asic (Move 5) |> Option.value_exn
  in
  assert (Option.is_none operation && List.equal String.equal before (list_text host));
  let host, _, operation =
    H.route_resource_input host reader ~asic Open |> Option.value_exn
  in
  assert (Option.is_none operation && (H.local host list.id).resources.raw);
  let s = Option.value_exn host.registry in
  let zoomed =
    W.apply
      s
      (Mutate
         { expected_revision = s.revision
         ; mutation = Set_zoom { workspace = list.workspace; tile = Some list.id }
         })
    |> Result.ok
    |> Option.value_exn
  in
  let host = H.receive host zoomed in
  assert (Option.is_none (H.resource_reader host list));
  let host, owner, operation =
    H.route_resource_input host list ~asic (Section "timing") |> Option.value_exn
  in
  assert (W.Tile_id.equal owner.id list.id && Option.is_some operation);
  assert (Resources_view.equal_mode (H.local host list.id).resources.mode Detail);
  assert (
    List.exists (page host list) ~f:(fun (_, spans) ->
      match String.lsplit2 (Evidence_style.text spans) ~on:':' with
      | Some ("Detail section", value) -> String.equal (String.strip value) "timing"
      | _ -> false))
;;

let%test_unit "adding the missing reader upgrades a retained stock fit layout in place" =
  let config = P.Presets.stock_config in
  let definitions =
    List.map config.definitions ~f:(fun d ->
      if not (String.equal d.key "resources")
      then d
      else
        { d with
          template = { d.template with views = List.drop_last_exn d.template.views }
        ; tiles = List.drop_last_exn d.tiles
        ; layout =
            Some
              (Leaf { tile = "resources"; min_width = 40; min_height = 14; weight = 1 })
        })
  in
  let registry =
    W.apply
      (W.initial ~session_id:(W.Session_id.of_string "legacy-stock"))
      (Initialize_config { config with definitions })
    |> Result.ok
    |> Option.value_exn
  in
  let workspace =
    List.find_exn registry.workspaces ~f:(fun w ->
      Option.equal String.equal w.preset (Some "resources"))
  in
  let mutate (s : W.Snapshot.t) mutation =
    W.apply s (Mutate { expected_revision = s.revision; mutation }) |> Result.ok |> Option.value_exn
  in
  let list =
    List.find_exn registry.tiles ~f:(fun tile ->
      W.Workspace_id.equal tile.workspace workspace.id && String.equal tile.kind "resources")
  in
  let registry = mutate registry (Set_zoom { workspace = workspace.id; tile = Some list.id }) in
  let workspace = W.workspace registry workspace.id in
  let host = { (H.receive H.empty registry) with active = Some workspace.id; focus = Some list.id } in
  let resources, asic = Resources_view_test.imported () in
  let resources =
    { resources with mode = Detail; selected = Some "data"; section = "timing"; raw = true }
  in
  let host = H.set_local host list.id { (H.local host list.id) with resources; filter = "data" } in
  let repairs = H.resource_pair_repairs registry workspace in
  let updated = List.fold repairs ~init:registry ~f:mutate in
  List.iter registry.tiles ~f:(fun tile ->
    assert (W.Tile.equal tile (W.tile updated tile.id)));
  assert (
    List.equal
      W.Config_workspace.equal
      registry.config_workspaces
      updated.config_workspaces);
  let workspace = W.workspace updated workspace.id in
  assert (Option.is_none workspace.zoomed_tile && List.is_empty (H.resource_pair_repairs updated workspace));
  let host = H.receive host updated in
  let tiles = H.tiles host in
  let keys = H.layout_keys host tiles in
  assert (List.mem keys "resource-detail" ~equal:String.equal);
  let reader = Option.value_exn (H.resource_reader host list) in
  let _, data, _ = Host_view.refinement_fixture (Option.value_exn (P.Presets.find "resources")) in
  let step host id =
    let c = List.find_exn (H.catalog host ~project:None ~jobs:[]) ~f:(fun c -> String.equal c.id id) in
    match c.action with
    | Orient_resources orientation ->
      let host = H.set_resource_orientation host workspace.id orientation in
      let owner = H.local host list.id in
      assert (phys_equal owner.resources resources && String.equal owner.filter "data");
      let page tile = Host_view.resource_page host { data with asic } tile ~width:60 ~height:32 in
      assert (List.exists (page list) ~f:(function Some (`Resource "data"), _ -> true | _ -> false));
      assert (List.exists (page reader) ~f:(fun (_, spans) ->
        String.is_substring (Evidence_style.text spans) ~substring:"Raw contract"));
      let saved =
        Presentation_preferences.capture host ~project_key:"resources"
        |> Presentation_preferences.encode |> Presentation_preferences.decode ~project_key:"resources"
      in
      let restored = Presentation_preferences.apply saved (H.receive H.empty updated) in
      assert (List.length restored.resource_orientations = 1);
      let replacement =
        { updated with session_id = W.Session_id.of_string "replacement" }
      in
      assert (List.is_empty
        (Presentation_preferences.apply saved (H.receive restored replacement)).resource_orientations);
      let d = Option.value_exn (H.render_definition restored workspace) in
      (match P.Layout.compute d ~width:120 ~height:40 ~kinds:keys with
       | Compact -> assert false
       | Grid cells ->
         let cell key = List.Assoc.find_exn (List.zip_exn keys cells) key ~equal:String.equal in
         let l = cell "resources" and r = cell "resource-detail" in
         (match orientation with
          | Stacked -> assert (l.x = r.x && l.y + l.height = r.y)
          | Side_by_side -> assert (l.y = r.y && l.x + l.width = r.x)));
      host
    | _ -> assert false
  in
  let host = step host "resources.layout.stacked" in
  assert (Option.equal W.Tile_id.equal host.focus (Some list.id));
  let host = step { host with focus = Some reader.id } "resources.layout.side-by-side" in
  assert (Option.equal W.Tile_id.equal host.focus (Some reader.id));
  let hidden = mutate updated (Set_tile_hidden { tile = reader.id; hidden = true }) in
  match H.resource_pair_repairs hidden (W.workspace hidden workspace.id) with
  | [ Set_tile_hidden { tile; hidden = false } ] -> assert (W.Tile_id.equal tile reader.id)
  | _ -> assert false
;;
