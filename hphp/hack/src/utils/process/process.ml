(*
 * Copyright (c) 2016, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the "hack" directory of this source tree.
 *
 *)

open Hh_prelude
open Ocaml_overrides
open Stack_utils

module Entry = struct
  type 'param t = ('param, unit, unit) Daemon.entry

  let register name entry =
    let daemon_entry =
      Daemon.register_entry_point name (fun params _channels -> entry params)
    in
    daemon_entry
end

(** In the blocking read_and_wait_pid call, we alternate between
  non-blocking consuming of output and a nonblocking waitpid.
  To avoid pegging the CPU at 100%, sleep for a short time between
  those. *)
let sleep_seconds_per_retry = 0.04

let chunk_size = 65536

(** Reuse the buffer for reading. Just an allocation optimization. *)
let buffer = Bytes.create chunk_size

let env_to_array (env : Process_types.environment) : string array option =
  match env with
  | Process_types.Default -> None
  | Process_types.Empty -> Some [||]
  | Process_types.Augment augments_to_env ->
    (* deduping the env is not necessary. glibc putenv/getenv will grab the first
     * one *)
    let fullenv =
      Array.append (Array.of_list augments_to_env) (Unix.environment ())
    in
    Some fullenv
  | Process_types.Replace fullenv -> Some (Array.of_list fullenv)

let env_to_string (env : Process_types.environment) : string =
  match env with
  | Process_types.Default ->
    Printf.sprintf
      "=====Process environment inherited from parent process:\n%s\n"
      (String.concat ~sep:"\n" (Array.to_list (Unix.environment ())))
  | Process_types.Empty -> "Process environment is explicitly made empty"
  | Process_types.Augment additions ->
    Printf.sprintf
      "=====Process environment is augmented with:\n%s\n\n=====Parent process environment:\n%s\n"
      (String.concat ~sep:"\n" additions)
      (String.concat ~sep:"\n" (Array.to_list (Unix.environment ())))
  | Process_types.Replace fullenv ->
    Printf.sprintf
      "=====Process environment explicitly set to:\n%s\n"
      (String.concat ~sep:"\n" fullenv)

let status_to_string (status : Unix.process_status) : string =
  match status with
  | Unix.WEXITED i -> Printf.sprintf "Unix.WEXITED %d" i
  | Unix.WSIGNALED i -> Printf.sprintf "Unix.WSIGNALED %d" i
  | Unix.WSTOPPED i -> Printf.sprintf "Unix.WSTOPPED %d" i

(* make_result returns either (stdout,stderr) or a failure. *)
let make_result
    (status : Unix.process_status) (stdout : string) (stderr : string) :
    Process_types.process_result =
  let open Process_types in
  match status with
  | Unix.WEXITED 0 -> Ok { stdout; stderr }
  | Unix.WEXITED _
  | Unix.WSIGNALED _
  | Unix.WSTOPPED _ ->
    Error (Abnormal_exit { status; stdout; stderr })

(** [consume ~timeout_sec fd acc] polls [fd] for reading with a timeout
  and if that succeeds, reads from it into [acc]. If
  EOF is reached, the FD is closed *)
let consume ~timeout_sec fd acc :
    ([ `EOF | `Read | `Timeout ], Poll.Flags.t list) result =
  let open Result.Monad_infix in
  Poll.wait_fd_read_non_interrupted
    fd
    ~timeout_ms:(Some (Int.of_float (timeout_sec *. 1000.)))
  >>= function
  | Poll.Timeout -> Ok `Timeout
  | Poll.Event { ready; hup } ->
    (if ready then
      let bytes_read = Unix.read fd buffer 0 chunk_size in
      let chunk = String.sub (Bytes.to_string buffer) ~pos:0 ~len:bytes_read in
      Stack.push chunk acc);
    if hup then (
      Unix.close fd;
      Ok `EOF
    ) else
      Ok `Read

(** [consume_till_timeout_or_eof ~timeout_sec fd acc] keeps consuming
  from FD until either the timeout occurs or we reach end of file.
  In the latter case, the FD is closed *)
let rec consume_till_timeout_or_eof ~timeout_sec fd acc :
    ([ `EOF | `Timeout ], Poll.Flags.t list) result =
  if Float.(timeout_sec < 0.0) then
    Ok `Timeout
  else
    let start_t = Unix.time () in
    let open Result.Monad_infix in
    consume ~timeout_sec fd acc >>= function
    | `Timeout -> Ok `Timeout
    | `EOF -> Ok `EOF
    | `Read ->
      let consumed_t = Unix.time () -. start_t in
      let timeout_sec = timeout_sec -. consumed_t in
      consume_till_timeout_or_eof ~timeout_sec fd acc

(** [maybe_consume ?timeout_sec fd_ref acc] reads from the FD
  if there is something to be read and accumulates the result in [acc].
  The [fd_ref] reference is set to None and the FD is closed when EOF is reached. *)
let maybe_consume
    ?(timeout_sec : float = 0.0)
    (fd_ref : Unix.file_descr option ref)
    (acc : string Stack_utils.Stack.t) : (unit, Poll.Flags.t list) result =
  match !fd_ref with
  | None -> Ok ()
  | Some fd ->
    let open Result.Monad_infix in
    consume_till_timeout_or_eof ~timeout_sec fd acc >>| ( function
    | `Timeout -> ()
    | `EOF ->
      fd_ref := None;
      () )

(** Read data from stdout and stderr until EOF is reached. Waits for
    process to terminate returns the stderr and stdout
    and stderr.

    Idempotent.

    If process exits with something other than (Unix.WEXITED 0), will return a
    Error *)
let read_and_wait_pid_nonblocking (process : Process_types.t) =
  let open Process_types in
  let { stdin_fd = _; stdout_fd; stderr_fd; lifecycle; acc; acc_err; info = _ }
      =
    process
  in
  match !lifecycle with
  | Lifecycle_killed_due_to_overflow_stdin
  | Lifecycle_exited _ ->
    Ok ()
  | Lifecycle_running { pid } ->
    let open Result.Monad_infix in
    maybe_consume stdout_fd acc >>= fun () ->
    maybe_consume stderr_fd acc_err >>= fun () ->
    (match Unix.waitpid [Unix.WNOHANG] pid with
    | (0, _) -> Ok ()
    | (_, status) ->
      let () = lifecycle := Lifecycle_exited status in
      (* Process has exited. Non-blockingly consume residual output. *)
      maybe_consume stdout_fd acc >>= fun () -> maybe_consume stderr_fd acc_err)

(** Returns true if read_and_close_pid would be nonblocking. *)
let is_ready (process : Process_types.t) : bool =
  (match read_and_wait_pid_nonblocking process with
  | Ok () -> ()
  | Error flags -> raise (Poll.Poll_exception flags));
  let open Process_types in
  match !(process.lifecycle) with
  | Lifecycle_running _ -> false
  | Lifecycle_killed_due_to_overflow_stdin
  | Lifecycle_exited _ ->
    true

let kill_and_cleanup_fds (pid : int) (fds : Unix.file_descr option ref list) :
    unit =
  Unix.kill pid Sys.sigkill;
  let maybe_close fd_ref =
    Option.iter !fd_ref ~f:(fun fd ->
        Unix.close fd;
        fd_ref := None)
  in
  List.iter fds ~f:maybe_close

(** Consumes from stdout and stderr pipes and waitpids on the process.
  Returns immediately if process has already been waited on (so this
  function is idempotent).

  The implementation is a little complicated because:
    (1) The pipe can get filled up and the child process will pause
        until it's emptied out.
    (2) If the child process itself forks a grandchild, the
        granchild will unknowingly inherit the pipe's file descriptors;
        in this case, the pipe will not provide an EOF as you'd expect.

  Due to (1), we can't just blockingly waitpid followed by reading the
  data from the pipe.

  Due to (2), we can't just read data from the pipes until an EOF is
  reached and then do a waitpid.

  We must do some weird alternating between them.
 *)
let rec read_and_wait_pid ~(retries : int) (process : Process_types.t) :
    Process_types.process_result =
  let open Process_types in
  let open Result.Monad_infix in
  let { stdin_fd = _; stdout_fd; stderr_fd; lifecycle; acc; acc_err; info = _ }
      =
    process
  in
  read_and_wait_pid_nonblocking process
  |> Result.map_error ~f:(fun err -> Poll_exn err)
  >>= fun () ->
  match !lifecycle with
  | Lifecycle_exited status ->
    make_result status (Stack.merge_bytes acc) (Stack.merge_bytes acc_err)
  | Lifecycle_killed_due_to_overflow_stdin -> Error Overflow_stdin
  | Lifecycle_running { pid } ->
    let fds = List.rev_filter_map ~f:( ! ) [stdout_fd; stderr_fd] in
    if List.is_empty fds then
      (* EOF reached for all FDs. Blocking wait. *)
      let (_, status) = Unix.waitpid [] pid in
      let () = lifecycle := Lifecycle_exited status in
      make_result status (Stack.merge_bytes acc) (Stack.merge_bytes acc_err)
    else
      let maybe_consume ?timeout_sec x y =
        maybe_consume ?timeout_sec x y
        |> Result.map_error ~f:(fun err -> Poll_exn err)
      in
      (* Consume output to clear the buffers which might
       * be blocking the process from continuing. *)
      maybe_consume ~timeout_sec:(sleep_seconds_per_retry /. 2.0) stdout_fd acc
      >>= fun () ->
      maybe_consume
        ~timeout_sec:(sleep_seconds_per_retry /. 2.0)
        stderr_fd
        acc_err
      >>= fun () ->
      (* EOF hasn't been reached for all FDs. Here's where we switch from
       * reading the pipes to attempting a non-blocking waitpid. *)
      (match Unix.waitpid [Unix.WNOHANG] pid with
      | (0, _) ->
        if retries <= 0 then
          let () = kill_and_cleanup_fds pid [stdout_fd; stderr_fd] in
          let stdout = Stack.merge_bytes acc in
          let stderr = Stack.merge_bytes acc_err in
          Error (Timed_out { stdout; stderr })
        else
          (* And here we switch from waitpid back to reading. *)
          read_and_wait_pid ~retries:(retries - 1) process
      | (_, status) ->
        (* Process has exited. Non-blockingly consume residual output. *)
        maybe_consume stdout_fd acc >>= fun () ->
        maybe_consume stderr_fd acc_err >>= fun () ->
        let () = lifecycle := Lifecycle_exited status in
        make_result status (Stack.merge_bytes acc) (Stack.merge_bytes acc_err))

let read_and_wait_pid ~(timeout : int) (process : Process_types.t) :
    Process_types.process_result =
  let retries =
    float_of_int timeout /. sleep_seconds_per_retry |> int_of_float
  in
  read_and_wait_pid ~retries process

let failure_msg (failure : Process_types.failure) : string =
  let open Process_types in
  match failure with
  | Timed_out { stdout; stderr } ->
    Printf.sprintf "Process timed out. stdout:\n%s\nstderr:\n%s\n" stdout stderr
  | Abnormal_exit { stdout; stderr; _ } ->
    Printf.sprintf
      "Process exited abnormally. stdout:\n%s\nstderr:\n%s\n"
      stdout
      stderr
  | Overflow_stdin -> Printf.sprintf "Process_aborted_input_too_large"
  | Poll_exn flags ->
    Printf.sprintf
      "Exception during `poll` syscall. Got error flags: %s"
      (Poll.Flags.to_string flags)

let send_input_and_form_result
    ?(input : string option)
    ~(info : Process_types.invocation_info)
    pid
    ~(stdin_parent : Unix.file_descr)
    ~(stdout_parent : Unix.file_descr)
    ~(stderr_parent : Unix.file_descr) : Process_types.t =
  Process_types.(
    let input_succeeded =
      match input with
      | None -> true
      | Some input ->
        let input = Bytes.of_string input in
        let written = Unix.write stdin_parent input 0 (Bytes.length input) in
        written = Bytes.length input
    in
    let lifecycle =
      if input_succeeded then
        Lifecycle_running { pid }
      else
        let () = Unix.kill pid Sys.sigkill in
        Lifecycle_killed_due_to_overflow_stdin
    in
    Unix.close stdin_parent;
    {
      info;
      stdin_fd = ref @@ None;
      stdout_fd = ref @@ Some stdout_parent;
      stderr_fd = ref @@ Some stderr_parent;
      acc = Stack.create ();
      acc_err = Stack.create ();
      lifecycle = ref @@ lifecycle;
    })

(**
 * Launches a process, optionally modifying the environment variables with ~env
 *)
let exec_no_chdir
    ~(prog : Exec_command.t)
    ?(input : string option)
    ~(env : Process_types.environment option)
    (args : string list) : Process_types.t =
  let prog = Exec_command.to_string prog in
  let env = Option.value env ~default:Process_types.Default in
  let info =
    {
      Process_types.name = prog;
      args;
      env;
      stack =
        Utils.Callstack
          (Stdlib.Printexc.get_callstack 100
          |> Stdlib.Printexc.raw_backtrace_to_string);
    }
  in
  let args = Array.of_list (prog :: args) in
  let (stdin_child, stdin_parent) = Unix.pipe () in
  let (stdout_parent, stdout_child) = Unix.pipe () in
  let (stderr_parent, stderr_child) = Unix.pipe () in
  Unix.set_close_on_exec stdin_parent;
  Unix.set_close_on_exec stdout_parent;
  Unix.set_close_on_exec stderr_parent;

  let pid =
    match env_to_array env with
    | None ->
      Unix.create_process prog args stdin_child stdout_child stderr_child
    | Some env ->
      Unix.create_process_env
        prog
        args
        env
        stdin_child
        stdout_child
        stderr_child
  in
  Unix.close stdin_child;
  Unix.close stdout_child;
  Unix.close stderr_child;
  send_input_and_form_result
    ?input
    ~info
    pid
    ~stdin_parent
    ~stdout_parent
    ~stderr_parent

let register_entry_point = Entry.register

type chdir_params = {
  cwd: string;
  prog: string;
  env: Process_types.environment;
  args: string list;
}

(** Wraps a entry point inside a Process, so we get Process's
 * goodness for free (read_and_wait_pid and is_ready). The entry will be
 * spawned into a separate process. *)
let run_entry
    ?(input : string option)
    (env : Process_types.environment)
    (entry : 'a Entry.t)
    (params : 'a) : Process_types.t =
  let (stdin_child, stdin_parent) = Unix.pipe () in
  let (stdout_parent, stdout_child) = Unix.pipe () in
  let (stderr_parent, stderr_child) = Unix.pipe () in
  let info =
    {
      Process_types.name = Daemon.name_of_entry entry;
      args = [];
      env;
      stack =
        Utils.Callstack
          (Stdlib.Printexc.get_callstack 100
          |> Stdlib.Printexc.raw_backtrace_to_string);
    }
  in
  let ({ Daemon.pid; _ } as daemon) =
    Daemon.spawn (stdin_child, stdout_child, stderr_child) entry params
  in
  Daemon.close daemon;
  send_input_and_form_result
    ?input
    ~info
    pid
    ~stdin_parent
    ~stdout_parent
    ~stderr_parent

let chdir_main (p : chdir_params) : 'a =
  Unix.chdir p.cwd;

  let args = Array.of_list (p.prog :: p.args) in
  let env = env_to_array p.env in
  match env with
  | None -> Unix.execvp p.prog args
  | Some env -> Unix.execvpe p.prog args env

let chdir_entry : (chdir_params, 'a, 'b) Daemon.entry =
  Entry.register "chdir_main" chdir_main

let exec
    (prog : Exec_command.t)
    ?(input : string option)
    ?(env : Process_types.environment option)
    (args : string list) : Process_types.t =
  exec_no_chdir ~prog ?input ~env args

let exec_with_working_directory
    ~(dir : string)
    (prog : Exec_command.t)
    ?(input : string option)
    ?(env = Process_types.Default)
    (args : string list) : Process_types.t =
  run_entry
    ?input
    env
    chdir_entry
    { cwd = dir; prog = Exec_command.to_string prog; env; args }
