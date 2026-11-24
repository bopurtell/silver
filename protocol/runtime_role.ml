(** Portable values shared by the native daemon and JavaScript frontend live in this
    library.

    A client receives identifiers and public metadata and asks the daemon to resolve
    them. Shared values carry serializable descriptions, not live native resources
    such as process handles or file descriptors. *)
