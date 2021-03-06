;***********************************************************************
; Copyright (C) 1989, G. E. Weddell.
;
; This file is part of RDM.
;
; RDM is free software: you can redistribute it and/or modify
; it under the terms of the GNU General Public License as published by
; the Free Software Foundation, either version 3 of the License, or
; (at your option) any later version.
;
; RDM is distributed in the hope that it will be useful,
; but WITHOUT ANY WARRANTY; without even the implied warranty of
; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
; GNU General Public License for more details.
;
; You should have received a copy of the GNU General Public License
; along with RDM.  If not, see <http://www.gnu.org/licenses/>.
;
;***********************************************************************

;***************************** PASS ONE ********************************
;***********************************************************************
; This file contains the procedures to perform the initial parse
; of LDM source.  Semantic checks that are performed:
; 
; 1. single schema statement.
; 2. acyclicity in "isa" hierarchy.
; 3. user property types ok.
; 4. constraint forms for classes ok.
; 5. variable declarations for queries and transactions ok.
; 6. classes and path functions in index declarations ok.
; 7. classes in store declarations ok.
; 8. each class in one and only one store declaration.
; 9. static store declarations include complete family.
;***********************************************************************

(defvar TokenList '(Schema gClass SubClass ClassWCon ClassWProps SubClassWProps SubClassWCon ClassWPropsCon SubClassWPropsCon Prop StringProp IntProp Query ParamQuery AllBody AllBodyPred AllBodyOrder AllBodyPredOrder AllBodyProj AllBodyPredProj AllBodyOrderProj AllBodyPredOrderProj OneBodyVar OneBodyPred OneBodyVarPred Exist ExistPred Forall Implies gOr gAnd gNot gEQ LT GT LE GE NE HasMax HasMin HasMaxPred HasMinPred Pred OrderAsc OrderDesc OrderAscList OrderDescList AddOp SubOp ModOp TimesOp DivOp UnMinusOp Constant gApply Trans ParamTrans Body BodyWLocVars ReturnBody ReturnBodyWLocVars Insert InsertWInits gDelete Assign DefSizeEst DefSelectEst DefOverlapEst DefFreqEst DefUnitTime DefUnitSpace Index gList gArray BinaryTree DistList DistPointer DistBinaryTree SearchCondList AscSearchCond DescSearchCond SCSearchCond Store))

(defun evalfexpr (L)
   (if (member (car L) TokenList)
      (eval (list (car L) (list 'quote (cdr L))))
      (eval (cons (car L) (mapcar (lambda (e) (list 'quote (evalfexpr e))) (cdr L))))))

(defun PassOne ()
   (evalfexpr Source)
   (setq Queries (reverse Queries))
   (setq Transactions (reverse Transactions))
   (setq Indices (reverse Indices))
   (setq Stores (reverse Stores))
   (ValidateStores))

;***********************************************************************
; Utility routines for flattening various lists.
;***********************************************************************

(defun IdList (P)
   (if (atom P)
      (list P)
      (cons (cadr P) (IdList (caddr P)))))

(defun ClassConList (P)
   (case (car P)
      (Pfd `((Pfd ,(PathFunc (cadr P)) ,(PathFuncList (caddr P)))))
      (Cover `((Cover ,(IdList (cadr P)))))
      (t `(,@(ClassConList (cadr P)) ,@(ClassConList (caddr P))))))

(defun PathFuncList (P)
   (case (car P)
      (PathFuncList `(,(PathFunc (cadr P)) ,@(PathFuncList (caddr P))))
      (t (list (PathFunc P)))))

(defun PathFunc (P)
   (case (car P)
      (SimpPF (cdr P))
      (CompPF (cons (cadr P) (PathFunc (caddr P))))))

(defun AsOpList (V P)
   (case (car P)
      (AsOp `((gEQ ,(ParseTerm (cadr P))
                ,(ValidateApply (AppendPF V (PathFunc (caddr P)))))))
      (AsOpList
         (cons `(gEQ ,(ParseTerm (cadr P))
                  ,(ValidateApply (AppendPF V (PathFunc (caddr P)))))
            (AsOpList V (cadddr P))))))

(defun InitList (P)
   (case (car P)
      (Init
         (list (ValidateInit `(Assign ,(ValidateApply
               (AppendPF (ParseTerm (cadr P)) (PathFunc (caddr P))))
            ,(ParseTerm (cadddr P))))))
      (InitList
         (cons (ValidateInit `(Assign ,(ValidateApply
                  (AppendPF (ParseTerm (cadr P)) (PathFunc (caddr P))))
               ,(ParseTerm (cadddr P))))
            (InitList (caddddr P))))))

;***********************************************************************
; Utility routines for access and maintenance of variable
; definitions on VarStack.
;***********************************************************************

(defun VarDecl (Type L &aux VList)
   (setq VList (VarDeclList Type (cadr L) (caddr L)))
   (mapc #'(lambda (Var)
         (if (null (Class? (ExpressionType Var)))
            (ReportError `(BadVarType
                         ,(if QueryName? 'query 'transaction)
                         ,QueryOrTransName))))
      VList)
   VList)

(defun VarDeclList (Type L1 L2)
   (if (and (atom L1) (atom L2)) 
      `((,Type ,L1 ,L2))
    (if (and (listp L1) (listp L2))
      (cons `(,Type ,(cadr L1) ,(cadr L2))
            (VarDeclList Type (caddr L1) (caddr L2)))
      (ReportError `(BadVarDecl
                   ,(if QueryName? 'query 'transaction)
                   ,QueryOrTransName)))))
      
(defun PushVars (Vars)
   (setq VarStack (cons '(**frame**) VarStack))
   (mapc #'(lambda (Var) 
         (setq VarStack (cons `(,(cadr Var) ,Var) VarStack)))
      Vars))

(defun PopVars ()
   (case (caar VarStack) (**frame** (PopVar)) (t (PopVar) (PopVars))))

(defun PopVar () (setq VarStack (cdr VarStack)))

(defun ParseTerm (S &aux Term)
   (if (atom S)
      (cond ((cadr (assoc S VarStack)))
            (t (ReportError `(UndefVar ,S
                            ,(if QueryName? 'query 'transaction)
                            ,QueryOrTransName)) S))
    (progn
      (setq Term (evalfexpr S))
      (case (car Term)
         ((UnMinusOp ModOp TimesOp DivOp AddOp SubOp)
            (if (not (member (ExpressionType Term) '(Integer Real DoubleReal)))
               (ReportError `(BadArithExpr
                            ,(if QueryName? 'query 'transaction)
                            ,QueryOrTransName))))
         (gApply (ValidateApply Term)))
      Term)))

(defun ParseIdList (L)
   (if (atom L)
      (list (ParseTerm L))
      (cons (ParseTerm (cadr L)) (ParseIdList (caddr L)))))

;***********************************************************************
; Non-terminal symbol functions.
;***********************************************************************

(defun SpecList (I L) I L ())

(defun Schema (L)
   (setq Schema (car L))
   (evalfexpr (cadr L))
   (ValidateSchema)
   (evalfexpr (caddr L))) 

(defun gClass (L) (NewClass (car L)))

(defun SubClass (L)
   (NewClass (car L))
   (AddSupClasses (car L) (IdList (cadr L))))
  
(defun ClassWCon (L)
   (NewClass (car L))
   (AddClassConstraints (car L) (ClassConList (cadr L))))
  
(defun ClassWProps (L)
   (NewClass (car L))
   (AddClassProps (car L) (IdList (cadr L))))
  
(defun SubClassWProps (L)
   (NewClass (car L))
   (AddSupClasses (car L) (IdList (cadr L)))
   (AddClassProps (car L) (IdList (caddr L))))
  
(defun SubClassWCon (L)
   (NewClass (car L))
   (AddSupClasses (car L) (IdList (cadr L)))
   (AddClassConstraints (car L) (ClassConList (caddr L))))
  
(defun ClassWPropsCon (L)
   (NewClass (car L))
   (AddClassProps (car L) (IdList (cadr L)))
   (AddClassConstraints (car L) (ClassConList (caddr L))))
  
(defun SubClassWPropsCon (L)
   (NewClass (car L))
   (AddSupClasses (car L) (IdList (cadr L)))
   (AddClassProps (car L) (IdList (caddr L)))
   (AddClassConstraints (car L) (ClassConList (cadddr L))))
  
(defun Prop (L) (NewProp (car L) (cadr L)))

(defun StringProp (L)
   (NewProp (car L) 'String)
   (AddPropConstraint (car L) `(Maxlen ,(Valof (cadr L)))))

(defun IntProp (L)
   (NewProp (car L) 'Integer)
   (AddPropConstraint (car L) `(Range ,(Valof (cadr L)) ,(Valof (caddr L)))))
  
(defun Query (L)
   (setq QueryName? t)
   (setq QueryOrTransName (car L))
   (NewQuery (car L) (evalfexpr `(,(caadr L) ,(car L) () ,@(cdadr L)))))

(defun ParamQuery (L)
   (setq QueryName? t)
   (setq QueryOrTransName (car L))
   (let ((Vars (VarDecl 'PVar (cadr L))))
      (PushVars Vars)
      (NewQuery (car L) (evalfexpr `(,(caaddr L) ,(car L) ,Vars ,@(cdaddr L))))
      (PopVars)))

(defun AllBody (L)
   (let ((Vars (VarDecl 'QVar (caddr L))))
      `(AllQuery ,(car L) (,@(cadr L) ,@Vars)
         (Find () (All (Proj) (Sort)) (ScanHeap ,@Vars) (AndHeap)))))

(defun AllBodyPred (L)
   (let ((Vars (VarDecl 'QVar (caddr L))) Pred)
      (PushVars Vars) (setq Pred (evalfexpr (cadddr L))) (PopVars) 
      `(AllQuery ,(car L) (,@(cadr L) ,@Vars)
         (Find () (All (Proj) (Sort)) (ScanHeap ,@Vars) (AndHeap ,Pred)))))

(defun AllBodyOrder (L)
   (let ((Vars (VarDecl 'QVar (caddr L))) Ord)
      (PushVars Vars) (setq Ord (evalfexpr (cadddr L))) (PopVars) 
      `(AllQuery ,(car L) (,@(cadr L) ,@Vars)
         (Find () (All (Proj) (Sort ,@Ord)) (ScanHeap ,@Vars) (AndHeap)))))

(defun AllBodyPredOrder (L)
   (let ((Vars (VarDecl 'QVar (caddr L))) Pred Ord)
      (PushVars Vars)
      (setq Pred (evalfexpr (cadddr L)))
      (setq Ord (evalfexpr (caddddr L)))
      (PopVars) 
      `(AllQuery ,(car L) (,@(cadr L) ,@Vars)
         (Find () (All (Proj) (Sort ,@Ord))
            (ScanHeap ,@Vars) (AndHeap ,Pred)))))

(defun AllBodyProj (L)
   (let ((Vars (VarDecl 'QVar (caddr L))))
      `(AllQuery ,(car L) (,@(cadr L) ,@Vars)
         (Find () (All (Proj ,@Vars) (Sort)) (ScanHeap ,@Vars) (AndHeap)))))

(defun AllBodyPredProj (L)
   (let ((Vars (VarDecl 'QVar (caddr L))) Pred)
      (PushVars Vars) (setq Pred (evalfexpr (cadddr L))) (PopVars) 
      `(AllQuery ,(car L) (,@(cadr L) ,@Vars)
         (Find () (All (Proj ,@Vars) (Sort))
            (ScanHeap ,@Vars) (AndHeap ,Pred)))))

(defun AllBodyOrderProj (L)
   (let ((Vars (VarDecl 'QVar (caddr L))) Ord)
      (PushVars Vars) (setq Ord (evalfexpr (cadddr L))) (PopVars) 
      `(AllQuery ,(car L) (,@(cadr L) ,@Vars)
         (Find () (All (Proj ,@Vars) (Sort ,@Ord))
            (ScanHeap ,@Vars) (AndHeap)))))

(defun AllBodyPredOrderProj (L)
   (let ((Vars (VarDecl 'QVar (caddr L))) Pred Ord)
      (PushVars Vars)
      (setq Pred (evalfexpr (cadddr L)))
      (setq Ord (evalfexpr (caddddr L)))
      (PopVars) 
      `(AllQuery ,(car L) (,@(cadr L) ,@Vars)
         (Find () (All (Proj ,@Vars) (Sort ,@Ord))
            (ScanHeap ,@Vars) (AndHeap ,Pred)))))

(defun OneBodyVar (L)
   (let ((Vars (VarDecl 'QVar (caddr L))))
      `(OneQuery ,(car L)
         (,@(cadr L) ,@Vars)
         (Find () (One) (ScanHeap ,@Vars) (AndHeap)))))

(defun OneBodyPred (L)
   `(OneQuery ,(car L) (,@(cadr L)) 
				  (Find () (One) (ScanHeap) (AndHeap ,(evalfexpr (caddr L))))))

(defun OneBodyVarPred (L)
   (let ((Vars (VarDecl 'QVar (caddr L))) Pred)
      (PushVars Vars) (setq Pred (evalfexpr (cadddr L))) (PopVars) 
      `(OneQuery ,(car L) (,@(cadr L) ,@Vars)
         (Find () (One) (ScanHeap ,@Vars) (AndHeap ,Pred)))))

(defun Exist (L)
   `(Find () (One) (ScanHeap ,@(VarDecl 'EVar (car L))) (AndHeap)))

(defun ExistPred (L)
   (let ((Vars (VarDecl 'EVar (car L))) Pred)
      (PushVars Vars) (setq Pred (evalfexpr (cadr L))) (PopVars)
      `(Find () (One) (ScanHeap ,@Vars) (AndHeap ,Pred))))

(defun Forall (L)
   (let ((Vars (VarDecl 'EVar (car L))) Pred)
      (PushVars Vars) (setq Pred (evalfexpr (cadr L))) (PopVars)
      `(gNot (Find () (One) (ScanHeap ,@Vars) (AndHeap (gNot ,Pred))))))

(defun Implies (L)
   `(gNot (Find () (One)
      (ScanHeap) (AndHeap ,(evalfexpr (car L)) (gNot ,(evalfexpr (cadr L)))))))

(defun gOr (L)
   `(gNot (Find () (One)
      (ScanHeap) (AndHeap (gNot ,(evalfexpr (car L))) (gNot ,(evalfexpr (cadr L)))))))

(defun gAnd (L)
   `(Find () (One) (ScanHeap) (AndHeap ,(evalfexpr (car L)) ,(evalfexpr (cadr L)))))

(defun gNot (L) `(gNot ,(evalfexpr (car L))))

(defun gEQ (L) `(gEQ ,(ParseTerm (car L)) ,(ParseTerm (cadr L))))

(defun LT (L) `(LT ,(ParseTerm (car L)) ,(ParseTerm (cadr L))))

(defun GT (L) `(GT ,(ParseTerm (car L)) ,(ParseTerm (cadr L))))

(defun LE (L) `(LE ,(ParseTerm (car L)) ,(ParseTerm (cadr L))))

(defun GE (L) `(GE ,(ParseTerm (car L)) ,(ParseTerm (cadr L))))

(defun NE (L) `(gNot (gEQ ,(ParseTerm (car L)) ,(ParseTerm (cadr L)))))

(defun HasMax (L)
   (let ((Var (ParseTerm (car L)))
         (PF (PathFunc (cadr L)))
         NewVar)
      (setq NewVar (NewVariable 'EVar (caddr Var)))
      `(gNot (Find () (One) (ScanHeap ,NewVar)
         (AndHeap (GT (gApply ,NewVar ,PF) (gApply ,Var ,PF)))))))

(defun HasMin (L)
   (let ((Var (ParseTerm (car L)))
         (PF (PathFunc (cadr L)))
         NewVar)
      (setq NewVar (NewVariable 'EVar (caddr Var)))
      `(gNot (Find () (One) (ScanHeap ,NewVar)
         (AndHeap (LT (gApply ,NewVar ,PF) (gApply ,Var ,PF)))))))

(defun HasMaxPred (L)
   (let ((Var (ParseTerm (car L)))
         (PF (PathFunc (cadr L)))
         (Pred (evalfexpr (caddr L)))
         NewVar)
      (setq NewVar (NewVariable 'EVar (caddr Var)))
      `(Find () (One) (ScanHeap) (AndHeap ,Pred
         (gNot (Find () (One) (ScanHeap ,NewVar) (AndHeap
            ,(ReplaceVar Pred Var NewVar)
            (GT (gApply ,NewVar ,PF) (gApply ,Var ,PF)))))))))

(defun HasMinPred (L)
   (let ((Var (ParseTerm (car L)))
         (PF (PathFunc (cadr L)))
         (Pred (evalfexpr (caddr L)))
         NewVar)
      (setq NewVar (NewVariable 'EVar (caddr Var)))
      `(Find () (One) (ScanHeap) (AndHeap ,Pred
         (gNot (Find () (One) (ScanHeap ,NewVar) (AndHeap
            ,(ReplaceVar Pred Var NewVar)
            (LT (gApply ,NewVar ,PF) (gApply ,Var ,PF)))))))))

(defun Pred (L)
   (let ((NewVar (NewVariable 'EVar (car L))))
      `(Find () (One) (ScanHeap ,NewVar)
         (AndHeap ,@(AsOpList NewVar (cadr L))))))

(defun OrderAsc (L) `((,(ParseTerm (car L)) Asc)))

(defun OrderDesc (L) `((,(ParseTerm (car L)) Desc)))

(defun OrderAscList (L)
   (cons `(,(ParseTerm (car L)) Asc) (evalfexpr (cadr L))))

(defun OrderDescList (L)
   (cons `(,(ParseTerm (car L)) Desc) (evalfexpr (cadr L))))

(defun AddOp (L) `(AddOp ,(ParseTerm (car L)) ,(ParseTerm (cadr L))))

(defun SubOp (L) `(SubOp ,(ParseTerm (car L)) ,(ParseTerm (cadr L))))

(defun ModOp (L) `(ModOp ,(ParseTerm (car L)) ,(ParseTerm (cadr L))))

(defun TimesOp (L) `(TimesOp ,(ParseTerm (car L)) ,(ParseTerm (cadr L))))

(defun DivOp (L) `(DivOp ,(ParseTerm (car L)) ,(ParseTerm (cadr L))))

(defun UnMinusOp (L) `(UnMinusOp ,(ParseTerm (car L))))

(defun Constant (L) (cons 'Constant L))

(defun gApply (L) `(gApply ,(ParseTerm (car L)) ,(PathFunc (cadr L))))

(defun Trans (L)
   (setq QueryName? nil)
   (setq QueryOrTransName (car L))
   (NewTrans (car L) (evalfexpr `(,(caadr L) ,(car L) () ,@(cdadr L)))))

(defun ParamTrans (L)
   (setq QueryName? nil)
   (setq QueryOrTransName (car L))
   (let ((Vars (VarDecl 'PVar (cadr L))))
      (PushVars Vars)
      (NewTrans (car L) (evalfexpr `(,(caaddr L) ,(car L) ,Vars ,@(cdaddr L))))
      (PopVars)))

(defun Body (L)
   `(StmtTrans ,(car L) ,(cadr L) (Block () ,@(evalfexpr (caddr L)))))

(defun BodyWLocVars (L)
   (let ((Vars (VarDecl 'QVar (caddr L))) StmtList)
      (PushVars Vars)
      (setq StmtList (evalfexpr (cadddr L)))
      (PopVars)
      `(StmtTrans ,(car L) ,(cadr L) (Block ,Vars ,@StmtList))))

(defun ReturnBody (L)
   `(ExprTrans
      ,(car L) ,(cadr L) (Block () ,@(evalfexpr (caddr L))) ,(ParseTerm (cadddr L))))

(defun ReturnBodyWLocVars (L)
   (let ((Vars (VarDecl 'QVar (caddr L))) StmtList Term)
      (PushVars Vars)
      (setq StmtList (evalfexpr (cadddr L)))
      (setq Term (ParseTerm (caddddr L)))
      (PopVars)
      `(ExprTrans ,(car L) ,(cadr L) (Block ,Vars ,@StmtList) ,Term)))

(defun StmtList (StmtList1 StmtList2) (append StmtList1 StmtList2))

(defun Insert (L) `((Insert ,(ValidateInsert (ParseIdList (car L))))))

(defun InsertWInits (L)
   (let ((Vars (ValidateInsert (ParseIdList (car L)))) IList)
      (PushVars Vars) (setq IList (InitList (cadr L))) (PopVars)
      `((Insert ,Vars ,@IList))))

(defun gDelete (L) `((gDelete ,(ParseIdList (car L)))))

(defun Assign (L)
   (let ((LHS (ParseTerm (car L))) Prop)
      (if (eq (car LHS) 'Apply)
         (progn
            (setq Prop (car (last (caddr LHS))))
            (if (not (eq Prop '|Id|)) (putprop Prop t 'Updated?))))
      (list (ValidateAssign `(Assign ,LHS ,(ParseTerm (cadr L)))))))

(defun DefSizeEst (L) (putprop (car L) (Valof (cadr L)) 'RCntEst))

(defun DefSelectEst (L) (putprop (car L) (Valof (cadr L)) 'SelectEst))

(defun DefOverlapEst (L)
   (let ((P (car L)))
      (putprop P (cons `(,(cadr L) ,(Valof (caddr L)))
         (get P 'OverlapEst)) 'OverlapEst)))

(defun DefFreqEst (L)
   (cond ((Query? (car L))
            (putprop (car L) (Valof (cadr L)) 'QueryFreqEst))
         ((Trans? (car L))
            (putprop (car L) (Valof (cadr L)) 'TransFreqEst))))

(defun DefUnitTime (L) (setq UnitTime (Valof (car L))))

(defun DefUnitSpace (L) (setq UnitSpace (Valof (car L))))

(defun Index (L)
   (let ((IName (car L)) (IClass (cadr L)))
      (if (Index? IName) (ReportError `(IndexExists ,IName)))
      (putprop IName t 'Index?)
      (evalfexpr `(,(caaddr L) ,IName ,IClass ,(cadaddr L) ,(caddaddr L)))
      (if (not (UserClass? IClass)) 
         (ReportError `(UndefClass ,IClass index ,IName)))
      (AddClassIndex IClass IName)
      (if (Distributed? IName) 
         (if (or (not (CheckPF IClass (DistPF IName)))
                 (not (UserClass? (Dom (DistPF IName))))) 
            (ReportError `(BadIndexDistPF ,IName))))
      (do ((SCondList (IndexSearchConds IName) (cdr SCondList))) ((null SCondList))
         (case (caar SCondList)
            (PFCond
               (if (not (CheckPF IClass (cadar SCondList))) 
                  (ReportError `(BadIndexPFSort ,IName))))
            (SCCond
               (if (not (member (cadar SCondList) (SubClasses+ IClass))) 
                  (ReportError `(BadIndexSCSort ,IName)))
               (setq IClass (cadar SCondList)))))
      (setq Indices (cons IName Indices))))


(defun gList (L)
   (putprop (car L) (cadr L) 'IndexClass)
   (putprop (car L) 'List 'IndexType))

(defun gArray (L)
   (putprop (car L) (cadr L) 'IndexClass)
   (putprop (car L) 'Array 'IndexType)
   (putprop (car L) (evalfexpr (cadddr L)) 'IndexSearchConds)
   (putprop (car L) t 'StaticIndex?)
   (putprop (car L) (Valof (caddr L)) 'IndexSize))
 
(defun BinaryTree (L)
   (putprop (car L) (cadr L) 'IndexClass)
   (putprop (car L) 'BinaryTree 'IndexType)
   (putprop (car L) (evalfexpr (caddr L)) 'IndexSearchConds))

(defun DistList (L)
   (let ((PF (PathFunc (caddr L))))
      (putprop (car L) (cadr L) 'IndexClass)
      (AddClassDistIndex (Dom PF) (car L))
      (putprop (car L) 'DistList 'IndexType)
      (putprop (car L) `((PFCond ,PF NoOrder)) 'IndexSearchConds)
      (putprop (car L) t 'Distributed?)
      (putprop (car L) PF 'DistPF)))

(defun DistPointer (L)
   (let ((PF (PathFunc (caddr L))))
      (putprop (car L) (cadr L) 'IndexClass)
      (AddClassDistIndex (Dom PF) (car L))
      (putprop (car L) 'DistPointer 'IndexType)
      (putprop (car L) `((PFCond ,PF NoOrder)) 'IndexSearchConds)
      (putprop (car L) t 'Distributed?)
      (putprop (car L) PF 'DistPF)))

(defun DistBinaryTree (L)
   (let ((PF (PathFunc (caddr L))))
      (putprop (car L) (cadr L) 'IndexClass)
      (AddClassDistIndex (Dom PF) (car L))
      (putprop (car L) 'DistBinaryTree 'IndexType)
      (putprop (car L)
         `((PFCond ,PF NoOrder) ,@(evalfexpr (cadddr L))) 'IndexSearchConds)
      (putprop (car L) t 'Distributed?)
      (putprop (car L) PF 'DistPF)))

(defun SearchCondList (L) `(,@(evalfexpr (car L)) ,@(evalfexpr (cadr L))))

(defun AscSearchCond (L) `((PFCond ,(PathFunc (car L)) Asc)))

(defun DescSearchCond (L) `((PFCond ,(PathFunc (car L)) Desc)))

(defun SCSearchCond (L) `((SCCond ,(car L))))

(defun Store (L)
   (let ((SName (car L)))
      (if (Store? SName) (ReportError `(StoreExists ,SName)))
      (putprop SName t 'Store?)
      (do ((CList (IdList (caddr L)) (cdr CList))) ((null CList))
         (if (null (UserClass? (car CList))) 
            (ReportError `(UndefClass ,(car CList) store ,SName)))
         (if (ClassStore (car CList)) 
            (ReportError `(MultipleClassStore ,(car CList))))
         (putprop SName (cons (car CList) (StoreClasses SName)) 'StoreClasses)
         (putprop (car CList) SName 'ClassStore))
      (case (caadr L)
         (Dynamic
            (putprop SName 'Dynamic 'StoreType))
         (Static
            (let ((Family nil))
               (do ((CList (StoreClasses SName) (cdr CList))) ((null CList))
                  (setq Family (SetUnion Family (SubClasses* (car CList)))))
               (do ((CList Family (cdr CList))) ((null CList))
                  (if (and (null (ClassCovers (car CList)))
                           (not (member (car CList) (StoreClasses SName))))
                     (ReportError `(BadStaticStore ,SName)))))
            (putprop SName t 'StaticStore?)
            (putprop SName (Valof (cadadr L)) 'StoreSize)))
      (setq Stores (cons SName Stores))))


;***********************************************************************
; The following functions validate various semantic constraints on
; LDM source.
;***********************************************************************

(defun ValidateInsert (VList)
   (mapc #'(lambda (V)
         (if (ClassCovers (ExpressionType V)) 
             (ReportError `(BadCreate ,QueryOrTransName))))
      VList)
   VList)
      

(defun ValidateSchema (&aux CProps)
   (mapc #'(lambda (C) (if (not (Prop? C)) (NewProp C C))) Classes)
   (mapc #'(lambda (C)
         (putprop C t 'UserClass?)
         (putprop C (ClassProps C) 'ClassUserProps)
         (putprop C (SupClasses C) 'SupUserClasses))
      Classes)
   (mapc #'(lambda (P) (putprop P t 'UserProp?)) Properties)
   (mapc 'NewClass BuiltInClasses)
   (IsaClose)
   (mapc #'(lambda (PName)
         (if (not (Class? (PropType PName))) 
            (ReportError
               `(UndefClass ,(PropType PName) property ,PName))))
      Properties)
   (mapc #'(lambda (CName)
         (do ((SCList (SupClasses CName) (cdr SCList))) ((null SCList))
            (if (not (UserClass? (car SCList))) 
               (ReportError `(NotUserClass
                            ,(car SCList) class ,CName))))
         (do ((PList (ClassProps CName) (cdr PList))) ((null PList))
            (if (not (Prop? (car PList))) 
               (ReportError `(UndefProp
                            ,(car PList) class ,CName))))
         (do ((SCList (SupClasses+ CName) (cdr SCList))) ((null SCList))
            (setq CProps (SetIntersection (ClassProps CName)
                  (ClassProps (car SCList))))
            (if CProps 
               (ReportError `(MultipleClassProp ,(car CProps) ,CName))))
         (do ((CoverList (ClassCovers CName) (cdr CoverList))) ((null CoverList))
            (if (SetDifference (car CoverList) (SubClasses CName)) 
               (ReportError `(BadCoverConstraint ,CName))))
         (do ((PfdList (ClassPfds CName) (cdr PfdList))) ((null PfdList))
            (CheckClassPF CName (caar PfdList))
            (do ((PFList (cadar PfdList) (cdr PFList))) ((null PFList))
               (CheckClassPF CName (car PFList)))))
      Classes))


(defun CheckClassPF (CName PF)
   (if (null (CheckPF CName PF)) 
      (ReportError `(BadPfdConstraint ,CName))))


(defun ValidateStores ()
   (mapc #'(lambda (CName)
         (if (and (UserClass? CName) (not (ClassCovers CName))) 
            (if (null (ClassStore CName)) 
               (ReportError `(UndefClassStore ,CName)))))
      Classes))


(defun ValidateApply (Term)
   (if (or (not (eq (car Term) 'Apply))
           (CheckPF (ExpressionType (cadr Term)) (caddr Term))) 
      Term
      (ReportError `(BadPfInExpr
                   ,(if QueryName? 'query 'transaction)
                   ,QueryOrTransName))))


(defun ValidateInit (Init)
   (if (member (ExpressionType (cadr Init)) (SupClasses* (ExpressionType (caddr Init)))) 
      Init
      (ReportError `(BadAssign ,QueryOrTransName))))


(defun ValidateAssign (Assign)
   (if (Match '(Assign (gApply ? (|Id|)) ?) Assign) 
      Assign
      (ValidateInit Assign)))


(defun CheckPF (CName PF)
   (if (null PF)
      t
      (or (equal PF '(|Id|))
             (and (member (car PF) (ClassProps* CName))
                  (CheckPF (PropType (car PF)) (cdr PF))))))
