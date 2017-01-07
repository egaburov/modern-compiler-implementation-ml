structure Translate = struct
  type exp = unit
end

structure Semant : sig
  type venv
  type tenv
  type expty

  val transProg : Absyn.exp -> unit
  val transExp : venv * tenv -> Absyn.exp -> expty
  val transDec : venv * tenv -> Absyn.dec -> {venv: venv, tenv: tenv}
  val transTy : tenv * { name : Absyn.symbol, ty : Absyn.ty, pos : Absyn.pos } -> Types.ty
  val transFun : venv * tenv * Absyn.fundec -> Env.enventry option
end = struct
  (* Aliases *)
  structure A = Absyn
  structure T = Types
  val error = ErrorMsg.error

  (* Type Definitions *)
  type venv = Env.enventry Symbol.table
  type tenv = T.ty Symbol.table
  type expty = { exp: Translate.exp, ty: T.ty }

  (* Type Checkers *)
  fun checkInt ({ exp, ty }, pos) =
    if ty = T.INT then
      ()
    else
      (error pos "expected an integer")

  fun checkString ({ exp, ty }, pos) =
    if ty = T.STRING then
      ()
    else
      (error pos "expected a string")

  fun checkBothInt (result1, result2, pos) =
    (checkInt (result1, pos); checkInt (result2, pos))

  fun checkBothIntOrString (result1, result2, pos) =
    case (result1, result2) of
      ({ exp, ty = T.INT }, { exp = _, ty = T.INT }) =>
        ()
    | ({ exp, ty = T.INT }, _) =>
        (error pos "expected an integer")
    | ({ exp, ty = T.STRING }, { exp = _, ty = T.STRING }) =>
        ()
    | ({ exp, ty = T.STRING }, _) =>
        (error pos "expected a string")
    | _ =>
        (error pos "expecting an integer or string")

  fun checkBothEq (result1, result2, pos) =
    case (result1, result2) of
      ({ exp, ty = T.INT }, _) =>
        checkBothIntOrString (result1, result2, pos)
    | ({ exp, ty = T.STRING }, _) =>
        checkBothIntOrString (result1, result2, pos)
    | ({ exp, ty = T.RECORD (fields1, _) }, { exp = _, ty = T.RECORD (fields2, _) }) =>
        if fields1 = fields2 then
          ()
        else
          (error pos "records are not of the same type")
    | ({ exp, ty = T.RECORD _ }, { exp = _, ty = T.NIL }) =>
        ()
    | ({ exp, ty = T.NIL }, { exp = _, ty = T.RECORD _ }) =>
        ()
    | ({ exp, ty = T.RECORD _ }, _) =>
        (error pos "expecting a record")
    | ({ exp, ty = T.ARRAY (ty1, _) }, { exp = _, ty = T.ARRAY (ty2, _) }) =>
        if ty1 = ty2 then
          ()
        else
          (error pos "type of array's elements mismatched")
    | ({ exp, ty = T.ARRAY _ }, { exp = _, ty }) =>
        (error pos "expecting an array")
    | _ => 
        (error pos "expecting an integer, string, array, or record")

  fun checkSame (result1, result2, pos) =
    case (result1, result2) of
      ({ exp = _, ty = T.NIL }, { exp = _, ty = T.NIL }) =>
        ()
    | ({ exp = _, ty = T.NIL }, _) =>
        (error pos "expecting nil")
    | ({ exp = _, ty = T.UNIT }, { exp = _, ty = T.UNIT }) =>
        ()
    | ({ exp = _, ty = T.UNIT }, _) =>
        (error pos "expecting unit")
    | ({ exp = _, ty = T.NAME _ }, _) =>
        ()
    | _ =>
        checkBothEq (result1, result2, pos)



  (* Translators *)
  fun transDec (venv, tenv) =
    let
      fun trdec (A.VarDec { name, escape, typ = NONE, init, pos }) =
            let
              val { exp, ty } = transExp (venv, tenv) init
            in
              { venv = Symbol.enter (venv, name, Env.VarEntry { ty = ty }), tenv = tenv }
            end
        | trdec (A.VarDec { name, escape, typ = SOME (tySym, _), init, pos }) =
            (case Symbol.look (tenv, tySym) of
               NONE =>
                 (error pos "undefined type"; { venv = venv, tenv = tenv })
             | SOME ty =>
                 { venv = Symbol.enter (venv, name, Env.VarEntry { ty = ty }), tenv = tenv }
            )
                
        | trdec (A.TypeDec decs) = 
            { venv = venv
            , tenv = List.foldr 
                (fn (ty, env) => Symbol.enter (env, #name ty, transTy (env, ty)))
                tenv decs 
            }
        | trdec (A.FunctionDec decs) =
            { tenv = tenv
            , venv = 
                List.foldr
                (fn (dec, env) => 
                  case transFun (env, tenv, dec) of
                    SOME entry =>
                      Symbol.enter (env, #name dec, entry)
                  | NONE =>
                      env)
                venv decs
            }
    in
      trdec
    end
  and transTy (tenv, { name, ty = A.NameTy (sym, symPos), pos }) =
        T.NAME (sym, ref (Symbol.look (tenv, sym)))
    | transTy (tenv, { name, ty = A.RecordTy fields, pos }) =
        let
          fun getFieldType { name, typ, pos, escape } =
            case Symbol.look (tenv, typ) of
              NONE =>
                (error pos "undefined type"; NONE)
            | SOME ty =>
                SOME (name, ty)
        in
          T.RECORD ( List.mapPartial getFieldType fields, ref () )
        end
    | transTy (tenv, { name, ty = A.ArrayTy (sym, symPos), pos }) =
        (case Symbol.look (tenv, sym) of
           NONE =>
             (error symPos "undefined type"; T.NIL)
         | SOME ty =>
             T.ARRAY (ty, ref ()))
  and transFun (venv, tenv, { name, params, result = SOME (result, resultPos), body, pos }) =
        (case Symbol.look (tenv, result) of
           NONE =>
             (error resultPos "result type is undefined"; NONE)
         | SOME resultTy =>
             let
               val params' = 
                  List.map (transParam (venv, tenv)) params
               val entry = Env.FunEntry { formals = List.map #ty params', result = resultTy }
               val venv' = Symbol.enter (venv, name, entry)
               fun addparam ({ name, ty }, env) =
                  Symbol.enter (env, name, Env.VarEntry { ty = ty })
             in
               transExp (List.foldr addparam venv' params', tenv) body;
               SOME entry
             end
        )
    | transFun (venv, tenv, { name, params, result = NONE, body, pos }) =
        let
          val params' = List.map (transParam (venv, tenv)) params
          fun addparam ({ name, ty }, env) =
            Symbol.enter (env, name, Env.VarEntry { ty = ty })
          val venv' = Symbol.enter (venv, name, Env.FunEntry { formals = List.map #ty params', result = T.NIL } )
          val { exp = _, ty = ty } = transExp (List.foldr addparam venv' params', tenv) body
          val entry = Env.FunEntry { formals = List.map #ty params', result = ty }
        in
          SOME entry
        end
  and transParam (venv, tenv) { name, escape, typ = typSym, pos } =
        case Symbol.look (tenv, typSym) of
          NONE =>
            (error pos "undefined paramter type"; { name = name, ty = T.NIL })
        | SOME ty =>
            { name = name, ty = ty }
  and transExp (venv, tenv) =
    let
      fun trexp (A.IntExp i) =
            { exp = (), ty = T.INT }
        | trexp (A.StringExp (s, pos)) =
            { exp = (), ty = T.STRING }
        | trexp (A.VarExp var) =
            trvar var
        | trexp (A.NilExp) =
            { exp = (), ty = T.NIL }
        | trexp (A.OpExp opExp) =
            transOp opExp
        | trexp (A.CallExp { func, args, pos }) =
            (case Symbol.look (venv, func) of
               NONE =>
                 (error pos "undefined function"; { exp = (), ty = T.NIL })
             | SOME (Env.FunEntry { formals, result }) =>
                (ListPair.map 
                  (fn (exp, frm) => 
                    (checkSame ({ exp = (), ty = frm }, trexp exp, pos))) 
                  (List.rev args, formals);
                 { exp = (), ty = result })
             | SOME (Env.VarEntry _) =>
                (error pos "expecting a function"; { exp = (), ty = T.NIL }))
        | trexp (A.RecordExp { fields, typ, pos }) = 
            (case Symbol.look (tenv, typ) of
               NONE =>
                (error pos "undefined type"; { exp = (), ty = T.NIL })
             | SOME (ty as (T.RECORD (tys, _))) =>
                (ListPair.map
                  (fn ((sym, exp, pos), (tySym, ty)) =>
                    if tySym = sym then
                      (checkSame ({ exp = (), ty = ty }, trexp exp, pos))
                    else 
                      (error pos ("expecting `" ^ Symbol.name tySym ^ "`, given `" ^ Symbol.name sym ^ "`"))
                  ) (List.rev fields, tys);
                 { exp = (), ty = ty })
             | SOME _ =>
                 (error pos "expecting a record"; { exp = (), ty = T.NIL }))
        | trexp (A.SeqExp exps) =
            (case exps of
               [] => 
                 { exp = (), ty = T.UNIT }
             | (exp, pos) :: [] =>
                 { exp = (), ty = #ty (trexp exp) }
             | (exp, pos) :: xs =>
                 (trexp exp;
                  trexp (A.SeqExp xs)))
        | trexp (A.AssignExp { var, exp, pos }) =
          let 
            val varResult = trvar var
            val expResult = trexp exp
          in
            (checkSame (varResult, expResult, pos); { exp = (), ty = T.UNIT })
          end
        | trexp (A.IfExp { test, then', else', pos }) =
            (case (trexp test, trexp then', Option.map trexp else') of
               ({ exp = _, ty = T.INT }, (thenExp as { exp = _, ty = thenTy }), SOME elseExp) =>
                 (checkSame (thenExp, elseExp, pos);
                  { exp = (), ty = thenTy })
             | ({ exp = _, ty = T.INT }, thenExp, NONE) =>
                 (checkSame ({ exp = (), ty = T.UNIT }, thenExp, pos);
                  { exp = (), ty = T.UNIT })
             | (testExp, _, _) =>
                 (error pos "test should be an integer";
                  { exp = (), ty = T.UNIT }))
        | trexp (A.WhileExp { test, body, pos }) =
            (case (trexp test, trexp body) of
               ({ exp = _, ty = T.INT }, { exp = _, ty = T.UNIT }) =>
                 { exp = (), ty = T.UNIT }
             | ({ exp = _, ty = T.INT }, bodyExp) =>
                 (error pos "while body must produce no value";
                  { exp = (), ty = T.UNIT })
             | _ =>
                 (error pos "while test must be an integer";
                  { exp = (), ty = T.UNIT }))
        | trexp (A.ForExp { var, lo, hi, body, pos, escape }) =
            let
              val venv' = Symbol.enter (venv, var, Env.VarEntry { ty = T.INT })
            in 
              (checkInt (trexp lo, pos); checkInt (trexp hi, pos);
               checkSame ({ exp = (), ty = T.UNIT }, transExp (venv', tenv) body, pos);
               { exp = (), ty = T.UNIT }
              )
            end
        | trexp (A.BreakExp _) =
            { exp = (), ty = T.UNIT }
        | trexp (A.ArrayExp { typ, size, init, pos }) =
            (case Symbol.look (tenv, typ) of
               NONE =>
                (error pos "undefined type"; { exp = (), ty = T.UNIT })
             | SOME arrayTy =>
                (checkSame ( { exp = (), ty = actual_ty arrayTy}
                           , { exp = (), ty = T.ARRAY (actual_ty (#ty (trexp init)), ref ()) }
                           , pos);
                 checkInt (trexp size, pos);
                 { exp = (), ty = T.ARRAY (arrayTy, ref ()) }))
        | trexp (A.LetExp { decs, body, pos }) =
            let
              val { venv = venv', tenv = tenv' } =
                List.foldl (fn (dec, { venv, tenv }) => transDec (venv, tenv) dec)
                  { venv = venv, tenv = tenv } decs

                val bodyExp = transExp (venv', tenv') body
            in
              { exp = (), ty = #ty bodyExp }
            end
      and transOp { left, right, pos, oper } =
        let
          val leftExp = trexp left
          val rightExp = trexp right
        in
          case oper of
            A.PlusOp => 
              (checkBothInt (leftExp, rightExp, pos);
               { exp = (), ty = T.INT })
          | A.MinusOp => 
              (checkBothInt (leftExp, rightExp, pos);
               { exp = (), ty = T.INT })
          | A.TimesOp => 
              (checkBothInt (leftExp, rightExp, pos);
               { exp = (), ty = T.INT })
          | A.DivideOp => 
              (checkBothInt (leftExp, rightExp, pos);
               { exp = (), ty = T.INT })
          | A.LtOp =>
              (checkBothIntOrString (leftExp, rightExp, pos);
               { exp = (), ty = T.INT })
          | A.LeOp =>
              (checkBothIntOrString (leftExp, rightExp, pos);
               { exp = (), ty = T.INT })
          | A.GtOp =>
              (checkBothIntOrString (leftExp, rightExp, pos);
               { exp = (), ty = T.INT })
          | A.GeOp =>
              (checkBothIntOrString (leftExp, rightExp, pos);
               { exp = (), ty = T.INT })
          | A.EqOp =>
              (checkBothEq (leftExp, rightExp, pos);
                { exp = (), ty = T.INT })
          | A.NeqOp =>
              (checkBothEq (leftExp, rightExp, pos);
                { exp = (), ty = T.INT })
        end
      and trvar (A.SimpleVar (id, pos)) =
            ( case Symbol.look (venv, id) of
               NONE =>
                (error pos ("undefined variable `" ^ Symbol.name id ^ "`" );
                  { exp = (), ty = T.INT })
             | SOME (Env.VarEntry { ty }) =>
                { exp = (), ty = actual_ty ty }
             | SOME _ =>
                (error pos "expecting a variable, not a function";
                 { exp = (), ty = T.INT })
            )
        | trvar (A.FieldVar (var, id, pos)) =
            let 
              val { exp, ty } = trvar var
            in
              case actual_ty ty of
                (record as (T.RECORD (fields, _))) =>
                  (case List.filter (fn (s, t) => s = id) fields of
                     [] =>
                        (error pos ("field `" ^ Symbol.name id ^ "` is not a member of that record type" );
                         { exp = (), ty = record })
                   | (s, t) :: _ =>
                        { exp = (), ty = t })
              | _ =>
                  (error pos "expecting a record variable"; { exp = (), ty = T.INT })
            end
        | trvar (A.SubscriptVar (var, exp, pos)) =
            let
              val { exp, ty } = trvar var
            in
              case actual_ty ty of
                (array as (T.ARRAY (arrayTy, _))) =>
                  { exp = (), ty = arrayTy }
              | _ =>
                  (error pos "expecting an array variable"; { exp = (), ty = T.INT })
            end
      and actual_ty ty =
        case ty of
          T.NAME (sym, opTy) =>
            (case !opTy of 
              NONE =>
                ty
            | SOME ty =>
                actual_ty ty
            )
        | _ => 
            ty
    in
      trexp
    end

  fun transProg exp = let
    val result = transExp (Env.base_venv, Env.base_tenv) exp
  in () end

end
