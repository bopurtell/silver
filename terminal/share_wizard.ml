open! Core
open Bonsai_term
module View_style = Terminal_presentation.Host_view
module Panel = Terminal_presentation.Panel
module Artifact_view = Terminal_presentation.Artifact_view

let title = "Share with Cobalt…"

type eligibility =
  | Checking
  | Available
  | Unavailable of string

type t =
  { project : (string * string) option
  ; eligibility : eligibility
  ; remembered : bool
  ; remember : bool
  ; busy : bool
  ; confirmed : bool
  ; notice : string option
  ; scroll : int
  ; pasting : bool
  }

let create project =
  { project
  ; eligibility =
      (match project with
       | None -> Unavailable Project_sharing.no_project
       | Some _ -> Checking)
  ; remembered = false
  ; remember = false
  ; busy = false
  ; confirmed = false
  ; notice = None
  ; scroll = 0
  ; pasting = false
  }
;;

type action =
  | Stay of t
  | Dismiss
  | Share of bool
  | Stop

let input t ~sharing (key : Terminal_presentation.Workspace_host.input) =
  match key with
  | Paste_start -> Stay { t with pasting = true }
  | Paste_end -> Stay { t with pasting = false }
  | _ when t.pasting -> Stay t
  | Previous -> Stay { t with scroll = Int.max 0 (t.scroll - 1) }
  | Next -> Stay { t with scroll = t.scroll + 1 }
  | _ when t.busy -> Stay t
  | Escape -> Dismiss
  | _ when Poly.equal t.eligibility Checking -> Stay t
  | Enter when t.confirmed -> Dismiss
  | Enter when Poly.equal t.eligibility Available && ((not sharing) || t.remember) ->
    Share t.remember
  | Enter when sharing || t.remembered -> Stop
  | Character 'r'
    when Poly.equal t.eligibility Available && (not t.remembered) && not t.confirmed ->
    Stay { t with remember = not t.remember }
  | Character 's' when (not t.confirmed) && (sharing || t.remembered) -> Stop
  | _ -> Stay t
;;

let render t ~sharing appearance ({ Dimensions.width; height } as dimensions) background =
  let width = Int.min width 86 in
  let framed = width >= 24 && height >= 5 in
  let inner_width = Int.max 1 (width - if framed then 4 else 0) in
  let text role s = View.text ~attrs:(View_style.Role.attrs appearance role) s in
  let eligibility =
    match t.eligibility with
    | Checking -> [ "Checking the current connection…" ]
    | Unavailable reason -> [ "Unavailable: " ^ Artifact_view.safe reason ]
    | Available -> []
  in
  let lines =
    (match t.project with
     | None -> [ "Project: none" ]
     | Some (name, root) ->
       [ "Project: " ^ Artifact_view.safe name; "Root: " ^ Artifact_view.safe root ])
    @ [ ((if sharing then "Sharing: on" else "Sharing: off")
         ^ if t.remembered then " (remembered for this project)" else "")
      ]
    @ eligibility
    @ [ ""
      ; "A local Cobalt can discover this project and connect to this Silver service."
      ; "Stop sharing removes the offer for new connections."
      ; "It does not revoke existing connections or interrupt jobs."
      ]
    @ (if Poly.equal t.eligibility Available && (not t.confirmed) && not t.remembered
       then
         [ ""; (if t.remember then "[x]" else "[ ]") ^ " Remember for this project [r]" ]
       else [])
    @ Option.to_list (Option.map t.notice ~f:Artifact_view.safe)
  in
  let controls =
    if t.busy
    then "Applying…"
    else if t.confirmed
    then "Enter / Esc  Back"
    else if Poly.equal t.eligibility Checking
    then "Esc  Cancel"
    else if Poly.equal t.eligibility Available && ((not sharing) || t.remember)
    then
      (if t.remember then "Enter  Share and remember" else "Enter  Share for this session")
      ^ (if sharing || t.remembered then "   s  Stop sharing" else "")
      ^ "   Esc  Cancel"
    else if sharing || t.remembered
    then "Enter / s  Stop sharing   Esc  Cancel"
    else "Esc  Back"
  in
  let wrap = View_style.wrap_cells ~width:inner_width in
  let body = List.concat_map lines ~f:wrap in
  let footer = wrap controls in
  let header = if framed then [] else [ text Heading title ] in
  let height =
    Int.min height (List.length body + List.length footer + if framed then 2 else 1)
  in
  let geometry =
    Panel.geometry ~framed ~width ~height ~horizontal_padding:1 ~vertical_padding:0
  in
  let capacity =
    Int.max 0 (geometry.content_height - List.length footer - List.length header)
  in
  let offset = Int.min t.scroll (Int.max 0 (List.length body - capacity)) in
  let modal =
    Panel.render
      appearance
      ~title:(text Heading title)
      ~geometry
      ~width
      ~height
      ~attrs:(View_style.Role.attrs appearance Border)
      (View.vcat
         (header
          @ List.map (List.take (List.drop body offset) capacity) ~f:(text Foreground)
          @ List.map footer ~f:(text Focus)))
    |> View_style.colored appearance Surface
  in
  View.zcat [ View.center modal ~within:dimensions; background ]
;;
