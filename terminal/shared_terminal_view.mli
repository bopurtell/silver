val header_rows : int

val render
  :  number:int
  -> cwd:string
  -> status:string
  -> snapshot:Cobalt_terminal_pool.Model.snapshot option
  -> dimensions:Bonsai_term.Dimensions.t
  -> Bonsai_term.View.t
