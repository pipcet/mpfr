read("metaMPFR_common.mpl"):

FUNCTION_SERIES := 0:
FUNCTION_SERIES_RATIONAL := %+1:
CONSTANT_SERIES := %+1:

###############################################################################
######################### We can now generate the code ########################
###############################################################################
# This procedure generate code for a straightforward evaluation of the series
# corresponding to a recurrence.
#   rec is a recurrence with inital conditions
#   type can take three values, depending on which series should be evaluated:
#     FUNCTION_SERIES -> produces code for evaluating sum( a(i)*x^i )
#     FUNCTION_SERIES_RATIONAL -> produces code for evaluating sum( a(i)*(p/q)^i )
#     CONSTANT_SERIES -> produces code for evaluating sum( a(i) )
#   name is the name the should be given to the produced procedure.
#   fofx is an optional parameter. It is the function being implemented.
#     -> if provided, this argument will be used to (heuristically) find the limits
#        of the function at +/-oo and find its asymptotical behavior.
#   *IMPORTANT NOTE*: it must be a function of the variable 'x'.
#                     Moreover, neither _f nor x shall be assigned at the time of
#                     calling the function
#    
generateStraightforwardAlgo := proc(rec, aofn, type, name, filename, fofx := _f(x))
  local a, b, n, fd, init_cond, nc, d, exponents, formalRec, c, s1, s2, p, q, hardconstant, f0, i0, ri0, i, j, var, var1, var2, var3, guard_bits, required_mulsi, required_divsi, temp, error_counter, error_in_loop, maxofti, additional_error:

  getname(aofn, a, n):

  required_mulsi := {}:
  required_divsi := {}:
  fd := fopen(filename, WRITE):

  # We check that we have a recurrence of the form a(n+d)=r(n)*a(n)
  # and we extract its canonical form:
  #    a(n+d) = c * s1(n)/s1(n+d) * s2(n+d)/s2(n) * p(n)/q(n) * a(n)
  #
  formalRec := checkOneTermRecurrence(rec, a(n)):
  decomposeOneTermRecurrence(formalRec, c, s1, s2, p, q):
  d := formalRec:-order:

  # We keep only non-trivial inital conditions
  init_cond := removeTrivialConditions(rec, a(n));
  nc := nops(init_cond):
  exponents := {1, d}:
  for i from 1 to nc do
    exponents := { op(exponents), init_cond[i][1] }
  od:
  exponents := findFixpointOfDifferences(exponents):
  exponents := exponents minus {0}:

  error_counter := []:

  fprintf(fd, "/* Evaluation by a straightforward algorithm */\n"):
  fprintf(fd, "/* Code automatically generated by metaMPFR. */\n"):

  fprintf(fd, "static int\n"):
  if (type=FUNCTION_SERIES)
    then fprintf(fd, "mpfr_%a (mpfr_ptr res, mpfr_srcptr x, mpfr_rnd_t rnd)\n", name):
  elif (type=FUNCTION_SERIES_RATIONAL)
    then fprintf(fd, "mpfr_%a (mpfr_ptr res, int u, int v, mpfr_rnd_t rnd)\n", name):
  elif (type=CONSTANT_SERIES)
    then fprintf(fd, "mpfr_%a (mpfr_ptr res, mpfr_rnd_t rnd)\n", name):
  fi:
  fprintf(fd, "{\n"):


  ######################################################
  #################### Declarations ####################
  ######################################################

  fprintf(fd, "  MPFR_ZIV_DECL (loop);\n"):
  fprintf(fd, "  MPFR_SAVE_EXPO_DECL (expo);\n"):
  fprintf(fd, "  mpfr_prec_t wprec;             /* working precision */\n"):
  fprintf(fd, "  mpfr_prec_t prec;              /* target precision */\n"):
  fprintf(fd, "  mpfr_prec_t err;               /* used to estimate the evaluation error */\n"):
  fprintf(fd, "  mpfr_prec_t correctBits;       /* estimates the number of correct bits*/\n"):
  fprintf(fd, "  unsigned long int k;\n"):
  fprintf(fd, "  unsigned long int conditionNumber;        /* condition number of the series */\n"):
  fprintf(fd, "  unsigned assumed_exponent;     /* used as a lowerbound of -EXP(f(x)) */\n"):
  fprintf(fd, "  int r;                         /* returned ternary value */\n"):
  fprintf(fd, "  mpfr_t s;                      /* used to store the partial sum */\n"):
  
  if (whattype(c) = 'fraction') or (whattype(c) = 'integer')
    then hardconstant := 0
    else hardconstant := 1
  fi:
  if (type=FUNCTION_SERIES) then hardconstant := 1 fi:

  if (hardconstant=1)
  then
    if (type=CONSTANT_SERIES)
      then fprintf(fd, "  mpfr_t x%d;                     /* used to store %a */\n", d, c):
    elif (type=FUNCTION_SERIES_RATIONAL)
      then fprintf(fd, "  mpfr_t x%d;                     /* used to store %a */\n", d, c*(u/v)^d):
    elif (type=FUNCTION_SERIES)
      then fprintf(fd, "  mpfr_t x%d;                     /* used to store %a */\n", d, c*x^d):
    fi:
  fi:

  if (type=FUNCTION_SERIES)
  then
    fprintf(fd, "  mpfr_t tmp;\n"):
    if (nops(exponents)-1 >= 1) then fprintf(fd, "  mpfr_t ") fi:
    for i from 1 to nops(exponents)-1 do
      fprintf(fd, "x%d", exponents[i]):
      if (i<nops(exponents)-1) then fprintf(fd, ", ") else fprintf(fd, ";                     /* used to store x^i */\n") fi
    od:
  fi:

  fprintf(fd, "  mpfr_t ");
  for i from 1 to nc do
    fprintf(fd, "tip%d", init_cond[i][1]):
    if (i<nc) then fprintf(fd, ", ") else fprintf(fd, "; /* used to store successive values of t_i */\n") fi:
  od:
  fprintf(fd, "  int "):
  for i from 1 to nc do
    fprintf(fd, "test%d", init_cond[i][1]):
    if (i<nc) then fprintf(fd, ", ") else fprintf(fd, ";\n") fi:
  od:
  fprintf(fd, "  int global_test;               /* used to test when the sum can be stopped */"):

  fprintf(fd, "\n"):
  fprintf(fd, "  /* Logging */\n"):
  if (type=FUNCTION_SERIES)
    then fprintf(fd, "  MPFR_LOG_FUNC ( (\"x[%%#R]=%%R rnd=%%d\", x, x, rnd), (\"res[%%#R]=%%R\", res, res) );\n\n")
  elif (type=FUNCTION_SERIES_RATIONAL)
    then fprintf(fd, "  MPFR_LOG_FUNC ( (\"x=u/v with u=%%d and v=%%d, rnd=%%d\", u, v, rnd), (\"res[%%#R]=%%R\", res, res) );\n\n")
  else fprintf(fd, "  MPFR_LOG_FUNC ( (\"rnd=%%d\", rnd), (\"res[%%#R]=%%R\", res, res) );\n\n")
  fi:


  ######################################################
  #################### Special cases ###################
  ######################################################

  if ( (type=FUNCTION_SERIES) or (type=FUNCTION_SERIES_RATIONAL) )
  then
    fprintf(fd, "  /* Special cases */\n"):
 
    if (type=FUNCTION_SERIES)
      then fprintf(fd, "  if (MPFR_UNLIKELY (MPFR_IS_NAN (x)))\n")
      else fprintf(fd, "  if (MPFR_UNLIKELY (v==0))\n")
    fi:
    fprintf(fd, "    {\n"):
    fprintf(fd, "      MPFR_SET_NAN (res);\n"):
    fprintf(fd, "      MPFR_RET_NAN;\n"):
    fprintf(fd, "    }\n"):

    if (init_cond[1][1] > 0) then f0 := 0 else f0 := init_cond[1][2] fi:
    if (type=FUNCTION_SERIES)
      then fprintf(fd, "  if (MPFR_UNLIKELY (MPFR_IS_ZERO (x)))\n")
      else fprintf(fd, "  if (MPFR_UNLIKELY (u==0))\n")
    fi:
    if (whattype(f0) = 'integer')
    then
      fprintf(fd, "    {\n"):
      fprintf(fd, "      return mpfr_set_si (res, %a, rnd);\n", f0):
      fprintf(fd, "    }\n")
    else
      printf("You need to provide a function mpfr_%a0(mpfr_t, mpfr_rnd_t) that evaluates %a with correct rounding\n", name, f0):
      fprintf(fd, "    {\n"):
      fprintf(fd, "      return mpfr_%a0 (res, rnd);\n", name):
      fprintf(fd, "    }\n")
    fi:

    if (type=FUNCTION_SERIES)
    then
      fprintf(fd, "  if (MPFR_UNLIKELY (MPFR_IS_INF (x)))\n"):
      fprintf(fd, "    {\n"):
      for i from -1 to 1 by 2 do  # Trick to handle both -oo and +oo
        if (i<0)
          then fprintf(fd, "      if (MPFR_IS_NEG (x))\n"):
          else fprintf(fd, "      else\n")
        fi:
        fprintf(fd, "        {\n"):
        if (i<0) then f0 := "m" else f0 := "p" fi:
        if (fofx <> _f(x))
        then
          f0 := limit(fofx, x=i*infinity):
          if (whattype(f0)='integer')
          then fprintf(fd, "          return mpfr_set_si (res, %a, rnd);\n", f0):
          elif (f0 = infinity) or (f0 = -infinity)
          then
            fprintf(fd, "          MPFR_SET_INF(res);\n"):
            if (f0>0)
            then fprintf(fd, "          MPFR_SET_POS(res);\n")
            else fprintf(fd, "          MPFR_SET_NEG(res);\n")
            fi:
            fprintf(fd, "          MPFR_RET(0);\n"):
          else
            if (i<0) then f0 := "m" else f0 := "p" fi:
          fi: 
        fi:
        if ((f0 = "p") or (f0 = "m"))
        then
          printf("You need to provide a function mpfr_%a%sinf(mpfr_t, mpfr_rnd_t) that evaluates lim(f(x), x=", name, f0):
          if (f0 = "m") then printf("-") fi:
          printf("inf) with correct rounding.\n"):
          fprintf(fd, "          return mpfr_%a%sinf (res, rnd);\n", name, f0)
        fi:
        fprintf(fd, "        }\n")
      od:
      fprintf(fd, "    }\n")
    fi:
  fi:


  ######################################################
  ################## Precomputations ###################
  ######################################################

  fprintf(fd, "\n"):
  fprintf(fd, "  /* Save current exponents range */\n"):
  fprintf(fd, "  MPFR_SAVE_EXPO_MARK (expo);\n\n"):

  if ( (type=FUNCTION_SERIES) or (type=FUNCTION_SERIES_RATIONAL) )
  then  fprintf(fd, "  /* FIXME: special case for large values of |x| ? */\n\n")
  fi:

  # Note : prec is the value such that we will try to compute an approximation
  # with relative error smaller than 2^(1-prec).
  # Several things may happen:
  #   1) We do not achieve the intended error: this is because we badly estimated the exponent of the result
  #   2) We achieve the error, but it is not sufficient to decide correct rounding (Ziv's bad case)
  # Against 1), we can try to make our estimate of the exponent better with any heuristic.
  # Against 2), we can consider more guard bits. 11 guard bits seem a good value for the beginning
  #   (statistically, we expect to fail in less than 0.1 % of the cases)
  # wprec is the precision used during the computation, in order to ensure the final relative error 2^(1-prec)
  #
  fprintf(fd, "  /* We begin with 11 guard bits */\n"):
  fprintf(fd, "  prec = MPFR_PREC (res) + 11;\n"):
  fprintf(fd, "  MPFR_ZIV_INIT (loop, prec);\n"):

  # TODO: the value here can be chosen completely heursitically. We could do something much better
  # when fofx is known by using asympt(fofx, x, 1). A clean implementation appears to be complex though.
  # We must catch errors if the development does not exist (e.g. AiryAi(-x));
  # We must find a separation after which the asymptotic behavior is valid (e.g. x>1)
  printf("The code contains a variable assumed_exponent arbitrarily set to 10. You can put any value heuristically chosen. The closer it is to -log_2(|f(x)|), the better it is.\n"):
  fprintf(fd, "  assumed_exponent = 10; /* TIP: You can put any value heuristically chosen. The closer it is to -log_2(|f(x)|), the better it is */\n"):

  # TODO: find a way of putting a rigorous value here.
  # This value *must* be rigorous: the safety of the implementation relies on it.
  # Precisely, we need to have sum(|a(i)*x^i|) <= 2^conditionNumber
  fprintf(fd, "  conditionNumber = xxx; /* FIXME: set a value such that sum(|a(i)*x^i|) <= 2^conditionNumber */\n"):
  printf("The code contains a variable conditionNumber that you must manually set to a suitable value, in order to ensure that sum_{i=0}^{infinity} |a(i)*x^i| <= 2^conditionNumber\n"):
  fprintf(fd, "  wprec = prec + ERRORANALYSISPREC + conditionNumber + assumed_exponent;\n"):


  ######################################################
  ################## Initialisations ###################
  ######################################################

  if (hardconstant=1)
  then
    fprintf(fd, "  mpfr_init (x%d);\n", d):
  fi:
  if (type = FUNCTION_SERIES)
  then
    fprintf(fd, "  mpfr_init (tmp);\n"):
    for i from 1 to nops(exponents)-1 do
      fprintf(fd, "  mpfr_init (x%d);\n", exponents[i])
    od:
  fi:

  for i from 1 to nc do
    fprintf(fd, "  mpfr_init (tip%d);\n", init_cond[i][1])
  od:
  fprintf(fd, "  mpfr_init (s);\n\n"):


  ######################################################
  ########## Ziv' loop: setting the precision ##########
  ######################################################

  fprintf(fd, "  /* ZIV' loop */\n"):
  fprintf(fd, "  for (;;)\n"):
  fprintf(fd, "    {\n"):

  fprintf(fd, "      MPFR_LOG_MSG ((\"Working precision: %%d\\n\", wprec, 0));\n\n"):
  if (hardconstant=1)
  then
    fprintf(fd, "      mpfr_set_prec (x%d, wprec);\n", d):
  fi:
  if (type = FUNCTION_SERIES)
  then
    fprintf(fd, "      mpfr_set_prec (tmp, wprec);\n"):
    fprintf(fd, "      if(mpfr_get_prec (x) > wprec)\n"):
    fprintf(fd, "        mpfr_set_prec (x1, wprec);\n"):
    fprintf(fd, "      else\n"):
    fprintf(fd, "        mpfr_set_prec (x1, mpfr_get_prec (x));\n"):
    for i from 2 to nops(exponents)-1 do
      fprintf(fd, "      mpfr_set_prec (x%d, wprec);\n", exponents[i])
    od:
  fi:

  for i from 1 to nc do
    fprintf(fd, "      mpfr_set_prec (tip%d, wprec);\n", init_cond[i][1])
  od:
  fprintf(fd, "      mpfr_set_prec (s, wprec);\n\n"):


  ######################################################
  ############ Ziv' loop: initial conditions ###########
  ######################################################

  fprintf(fd, "      mpfr_set_ui (s, 0, MPFR_RNDN);\n"):

  if (type = FUNCTION_SERIES)
  then
    fprintf(fd, "      mpfr_set (x1, x, MPFR_RNDN);\n"):
    error_counter := init_error_counter("x1", error_counter):
    for i from 2 to nops(exponents) do
        fprintf(fd, "      mpfr_mul (x%d, x%d, x%d, MPFR_RNDN);\n", exponents[i], exponents[i-1], exponents[i]-exponents[i-1]):
	var1 := sprintf("x%d", exponents[i]):
        var2 := sprintf("x%d", exponents[i-1]):
        var3 := sprintf("x%d", exponents[i]-exponents[i-1]):
	error_counter := error_counter_of_a_multiplication(var1, var2, var3, error_counter):
    od:
  fi:

  for i from 1 to nc do
    i0 := init_cond[i][1]:
    ri0 := init_cond[i][2]:  # We implement t_{i0} <- ri0
    if (whattype(ri0)='integer') or (whattype(ri0)='fraction')
    then
      if (type = FUNCTION_SERIES) and (i0 <> 0)
        then 
          var :=  sprintf("      mpfr_mul_si (tip%d, x%d, ", i0, i0):
          var1 := sprintf("tip%d", i0):
          var2 := sprintf("x%d", i0):
          error_counter := error_counter_of_a_multiplication(var1, var2, "", error_counter):
        else 
          var := sprintf("      mpfr_set_si (tip%d, ", i0):
          var1 := sprintf("tip%d", i0):
          error_counter := init_error_counter(var1, error_counter):
      fi:
      fprintf(fd, "%s%d, MPFR_RNDN);\n", var, numer(ri0)):
      if (whattype(ri0)='fraction')
      then
        fprintf(fd, "      mpfr_div_si (tip%d, tip%d, %d, MPFR_RNDN);\n", i0, i0, denom(ri0)):
        var1 := sprintf("tip%d", i0):
        error_counter := error_counter_of_a_multiplication(var1, var1, "", error_counter):
      fi:
    else
      printf("You need to provide a function mpfr_%a%d (mpfr_t, mpfr_rnd_t) that evaluates %a with faithful rounding.\n", name, i0, ri0): 
      fprintf(fd, "      mpfr_%a%d (tip%d, MPFR_RNDN);\n", name, i0, i0):
      var1 := sprintf("tip%d", i0):
      error_counter := init_error_counter(var1, error_counter):
      if (type = FUNCTION_SERIES) and (i0 <> 0)
      then
        fprintf(fd, "      mpfr_mul (tip%d, tip%d, x%d, MPFR_RNDN);\n", i0, i0, i0):
        var1 := sprintf("tip%d", i0):
        var2 := sprintf("x%d", i0):
        error_counter := error_counter_of_a_multiplication(var1, var1, var2, error_counter):
      fi:
    fi:

    if (type = FUNCTION_SERIES_RATIONAL) and (i0 <> 0)
    then
      var1 := sprintf("tip%d", i0):
      if (i0 = 1)
      then fprintf(fd, "      mpfr_mul_si (tip%d, tip%d, ", i0, i0):
      else
        required_mulsi := { op(required_mulsi), i0 }:
        fprintf(fd, "      mpfr_mul_si%d (tip%d, tip%d, ", i0, i0, i0):
      fi:
      for j from 1 to i0 do
        fprintf(fd, "u, "):
        error_counter := error_counter_of_a_multiplication(var1, var1, "", error_counter):
      od:
      fprintf(fd, "MPFR_RNDN);\n"):
      if (i0 = 1)
      then fprintf(fd, "      mpfr_div_si (tip%d, tip%d, ", i0, i0):
      else
        required_divsi := { op(required_divsi), i0 }:
        fprintf(fd, "      mpfr_div_si%d (tip%d, tip%d, ", i0, i0, i0):
      fi:
      for j from 1 to i0 do
        fprintf(fd, "v, "):
        error_counter := error_counter_of_a_multiplication(var1, var1, "", error_counter):
      od:
      fprintf(fd, "MPFR_RNDN);\n"):
    fi:

    fprintf(fd, "      mpfr_add (s, s, tip%d, MPFR_RNDN);\n\n", i0):
  od:

  if (whattype(c) = 'integer') or (whattype(c) = 'fraction')
  then
    if (type = FUNCTION_SERIES) and (c = -1)
    then
      fprintf(fd, "      MPFR_CHANGE_SIGN (x%d);\n", d):
    elif (type = FUNCTION_SERIES) and (c <> 1)
    then
      fprintf(fd, "      mpfr_mul_si (x%d, x%d, %d, MPFR_RNDN);\n", d, d, numer(c)):
      var1 := sprintf("x%d", d):
      error_counter := error_counter_of_a_multiplication(var1, var1, "", error_counter):
      if (whattype(c) = 'fraction')
      then
        fprintf(fd, "      mpfr_div_si (x%d, x%d, %d, MPFR_RNDN);\n", d, d, denom(c)):
        error_counter := error_counter_of_a_multiplication(var1, var1, "", error_counter):
      fi:
    fi:
  else
    printf("You need to provide a function mpfr_%a_cste (mpfr_t, mpfr_rnd_t) that evaluates %a with faithful rounding.\n", name, c):
    if (type = CONSTANT_SERIES)
    then
      fprintf(fd, "      mpfr_%a_cste (x%d, MPFR_RNDN);\n", name, d):
      var1 := sprintf("x%d", d):
      error_counter := init_error_counter(var1, error_counter):
    elif (type = FUNCTION_SERIES) then
      fprintf(fd, "      mpfr_%a_cste (tmp, MPFR_RNDN);\n", name):
      error_counter := init_error_counter("tmp", error_counter):
      fprintf(fd, "      mpfr_mul (x%d, tmp, x%d, MPFR_RNDN);\n", d, d):
      var1 := sprintf("x%d", d):
      error_counter := error_counter_of_a_multiplication(var1, "tmp", var1, error_counter):
    elif (type = FUNCTION_SERIES_RATIONAL) then
      fprintf(fd, "      mpfr_%a_cste (x%d, MPFR_RNDN);\n", name, d):
      var1 := sprintf("x%d", d):
      error_counter := init_error_counter(var1, error_counter):
      if (d = 1)
      then fprintf(fd, "      mpfr_mul_si (x%d, x%d, ", d, d):
      else
        required_mulsi := { op(required_mulsi), d }:
        fprintf(fd, "      mpfr_mul_si%d (x%d, x%d, ", d, d, d):
      fi:
      for j from 1 to d do
        fprintf(fd, "u, "):
        error_counter := error_counter_of_a_multiplication(var1, var1, "", error_counter):
      od:
      fprintf(fd, "MPFR_RNDN);\n"):
      var1 := sprintf("x%d", d):
      if (d = 1)
      then fprintf(fd, "      mpfr_div_si (x%d, x%d, ", d, d):
      else
        required_divsi := { op(required_divsi), d }:
        fprintf(fd, "      mpfr_div_si%d (x%d, x%d, ", d, d, d):
      fi:
      for j from 1 to d do
        fprintf(fd, "v, "):
        error_counter := error_counter_of_a_multiplication(var1, var1, "", error_counter):
      od:
      fprintf(fd, "MPFR_RNDN);\n"): 
    fi:
  fi:

  ######################################################
  ######### Ziv' loop: evaluation of the series ########
  ######################################################

  fprintf(fd, "\n"):
  fprintf(fd, "      /* Evaluation of the series */\n"):
  fprintf(fd, "      k = %d;\n", d):
  fprintf(fd, "      for (;;)\n"):
  fprintf(fd, "        {\n"):
  if (init_cond[1][1] <> 0) then fprintf(fd, "          k += %d;\n", init_cond[1][1]) fi:

  for i from 1 to nc do
    error_in_loop := 0:
    i0 := init_cond[i][1]:
    if (hardconstant = 1)
    then 
      fprintf(fd, "          mpfr_mul (tip%d, tip%d, x%d, MPFR_RNDN);\n", i0, i0, d):
      var1 := sprintf("x%d", d):
      error_in_loop := error_in_loop + 1 + find_in_error_counter(var1, error_counter):
    else
      var := sprintf("tip%d", i0):
      temp := generate_multiply_rational(fd, var, var, c, [[var, error_in_loop]], "          "):
      error_in_loop := find_in_error_counter(var, temp):
      if (type = FUNCTION_SERIES_RATIONAL)
      then
        if (d=1)
        then
          fprintf(fd, "          mpfr_mul_si (tip%d, tip%d, u, MPFR_RNDN);\n", i0, i0):
          fprintf(fd, "          mpfr_div_si (tip%d, tip%d, v, MPFR_RNDN);\n", i0, i0):
	  error_in_loop := error_in_loop + 2:
        else
          required_mulsi := { op(required_mulsi), d }:
          fprintf(fd, "          mpfr_mul_si%d (tip%d, tip%d", d, i0, i0):
          for j from 1 to d do fprintf(fd, ", u") od:
          fprintf(fd, ", MPFR_RNDN);\n"):
	  error_in_loop := error_in_loop + d:

          required_divsi := { op(required_divsi), d }:
          fprintf(fd, "          mpfr_div_si%d (tip%d, tip%d", d, i0, i0):
          for j from 1 to d do fprintf(fd, ", v") od:
          fprintf(fd, ", MPFR_RNDN);\n" ):
	  error_in_loop := error_in_loop + d:
        fi
      fi
    fi:
    var := sprintf("tip%d", i0):

    temp := generate_multiply_poly(fd, var, var, subs(n=k-d, p/q), [[var, error_in_loop]], "          "):
    required_mulsi := { op(required_mulsi), op(temp[1]) }:
    required_divsi := { op(required_divsi), op(temp[2]) }:
    error_in_loop := find_in_error_counter(var, temp[3]):
    temp := generate_multiply_poly(fd, "tmp", var, subs(n=k, s2/s1), [[var, error_in_loop]], "          "):
    required_mulsi := { op(required_mulsi), op(temp[1]) }:
    required_divsi := { op(required_divsi), op(temp[2]) }:

    fprintf(fd, "          mpfr_add (s, s, tmp, MPFR_RNDN);\n"):
    
    if (i<nc) then fprintf(fd, "\n          k += %d;\n", init_cond[i+1][1]-i0)
    else  fprintf(fd, "\n          k += %d;\n", d-i0)
    fi:
  od:


  ######################################################
  ################### Error analysis ###################
  ######################################################

  maxofti := 0: # store the maximum of the error counters of the initial conditions
  for i from 1 to nc do
    var := sprintf("tip%d", init_cond[i][1]):
    if find_in_error_counter(var, error_counter) > maxofti
      then maxofti := find_in_error_counter(var, error_counter):
    fi:
  od:
  additional_error := find_in_error_counter("tmp", temp[3]) - error_in_loop:


  ######################################################
  #### Ziv' loop: stopping criterion for the series ####
  ######################################################

  # The first neglected term is tk, so the remainder is made by
  # tk + t(k+d) + t(k+2d).... and the corresponding series
  # beginning with t(k+1), t(k+2), etc. up to t(k+d-1).
  #
  # We have t(k0+d) = c*s1(k0)/s1(k0+d) * s2(k0+d)/s2(k0)* p(k0)/q(k0) * x^d t(k0)
  # (where x=u/v or x=1 in cases of rational series or constant series)
  # So it suffices that:
  # forall k0>=k-d, |c * s1(k0)/s1(k0+d) * s2(k0+d)/s2(k0) * p(k0)/q(k0) * x^d| <= 1/2     (1)
  #
  # If this is true, |tk| = |c*s1(k-d)/s1(k) * s2(k)/s2(k-d)* p(k-d)/q(k-d) * x^d t(k-d)| <= t(k-d)/2
  # This is also true for larger values of k, so we can bound |tk + t(k+d) + t(k+2d) + ...| by |t(k-d)|.
  # And the same holds for |t(k+1) + ...|, |t(k+2) + ...|, etc. up to |t(k+d-1)+...|.
  #
  # global_test depends on k and we must satisfy:
  #  "if (global_test) then (1) holds".
  #
  # the total remainder is bounded by 2*nc*tk.

  fprintf(fd, "          global_test = xxx; /* FIXME: set the value in order to ensure that, whenever global_test is true, we have: forall k'>=k, |r(k')*x^d| <= 1/2, where r is the fraction such that a(n)=r(n)a(n-d)*/\n"):
  printf("The code contains a variable global_test that you must manually set to a suitable value, in order to ensure that when global_test is true, the following holds:\n"):
  printf("        forall k'>=k, |r(k')*x^d| <= 1/2, where r is the fraction such that a(n)=r(n)a(n-d)\n"):
  guard_bits := 1+1+ceil(log[2](nc)):
  for i from 1 to nc do
    i0 := init_cond[i][1]:
    fprintf(fd, "          test%d = ( (!MPFR_IS_ZERO(s))\n", i0):
    fprintf(fd, "                    && ( MPFR_IS_ZERO(tip%d)\n", i0):
    fprintf(fd, "                         || (MPFR_EXP(tip%d) + (mp_exp_t)prec + %d <= MPFR_EXP(s))\n", i0, guard_bits):
    fprintf(fd, "                         )\n"):
    fprintf(fd, "                    );\n"):
  od:
  fprintf(fd, "          if (");
  for i from 1 to nc do
    fprintf(fd, "test%d && ", init_cond[i][1]):
  od:
  fprintf(fd, "global_test)\n"):
  fprintf(fd, "            break;\n"):
  fprintf(fd, "        }\n\n"):


  ######################################################
  ############## Ziv' loop: testing final ##############
  ######################################################

  fprintf(fd, "      MPFR_LOG_MSG ((\"Truncation rank: %%lu\\n\", k));\n\n"):
  fprintf(fd, "      err = ERRORANALYSISK + conditionNumber - MPFR_GET_EXP (s);\n\n"):
  fprintf(fd, "      /* err is the number of bits lost due to the evaluation error */\n"):
  fprintf(fd, "      /* wprec-(prec+1): number of bits lost due to the approximation error */\n"):
  fprintf(fd, "      MPFR_LOG_MSG ((\"Roundoff error: %%Pu\\n\", err));\n"):
  fprintf(fd, "      MPFR_LOG_MSG ((\"Approxim error: %%Pu\\n\", wprec-prec-1));\n\n"):
  fprintf(fd, "      if (wprec < err+1)\n"):
  fprintf(fd, "        correct_bits=0;\n"):
  fprintf(fd, "      else\n"):
  fprintf(fd, "        {\n"):
  fprintf(fd, "          if (wprec < err+prec+1)\n"):
  fprintf(fd, "            correct_bits =  wprec - err - 1;\n"):
  fprintf(fd, "          else\n"):
  fprintf(fd, "            correct_bits = prec;\n"):
  fprintf(fd, "        }\n\n"):
  fprintf(fd, "      if (MPFR_LIKELY (MPFR_CAN_ROUND (s, correct_bits, MPFR_PREC (y), rnd)))\n"):
  fprintf(fd, "        break;\n\n"):

  fprintf(fd, "      if (correct_bits == 0)\n"):
  fprintf(fd, "        {\n"):
  fprintf(fd, "          assumed_exponent *= 2;\n"):
  fprintf(fd, "          MPFR_LOG_MSG ((\"Not a single bit correct (assumed_exponent=%%lu)\\n\",\n"):
  fprintf(fd, "                         assumed_exponent));\n"):
  fprintf(fd, "          wprec = prec + ERRORANALYSISK + conditionNumber + assumed_exponent;\n"):
  fprintf(fd, "        }\n"):
  fprintf(fd, "      else\n"):
  fprintf(fd, "        {\n"):
  fprintf(fd, "          if (correct_bits < prec)\n"):
  fprintf(fd, "            { /* The precision was badly chosen */\n"):
  fprintf(fd, "              MPFR_LOG_MSG ((\"Bad assumption on the exponent of %s(x)\", 0));\n", name):
  fprintf(fd, "              MPFR_LOG_MSG ((\" (E=%%ld)\\n\", (long) MPFR_GET_EXP (s)));\n"):
  fprintf(fd, "              wprec = prec + err + 1;\n"):
  fprintf(fd, "            }\n"):
  fprintf(fd, "          else\n"):
  fprintf(fd, "            { /* We are really in a bad case of the TMD */\n"):
  fprintf(fd, "              MPFR_ZIV_NEXT (loop, prec);\n\n"):

  fprintf(fd, "              /* We update wprec */\n"):
  fprintf(fd, "              /* We assume that K will not be multiplied by more than 4 */\n"):
  fprintf(fd, "              wprec = prec + ERRORANALYSIS4K + conditionNumber\n"):
  fprintf(fd, "                - MPFR_GET_EXP (s);\n"):
  fprintf(fd, "            }\n"):
  fprintf(fd, "        }\n\n"):

  fprintf(fd, "    } /* End of ZIV loop */\n\n"):
  fprintf(fd, "  MPFR_ZIV_FREE (loop);\n\n"):
  fprintf(fd, "  r = mpfr_set (res, s, rnd);\n\n"):


  ######################################################
  ################ Clearing everything #################
  ######################################################

  fprintf(fd, "  mpfr_clear (s);\n"):
  if (hardconstant=1)
  then
    fprintf(fd, "  mpfr_clear (x%d);\n", d):
  fi:
  if (type = FUNCTION_SERIES)
  then
    fprintf(fd, "  mpfr_clear (tmp);\n"):
    for i from 1 to nops(exponents)-1 do
      fprintf(fd, "  mpfr_clear (x%d);\n", exponents[i]):
    od:
  fi:

  for i from 1 to nc do
    fprintf(fd, "  mpfr_clear (tip%d);\n", init_cond[i][1]):
  od:

  fprintf(fd, "\n"):
  fprintf(fd, "  MPFR_SAVE_EXPO_FREE (expo);\n"):
  fprintf(fd, "  return mpfr_check_range (res, r, rnd);\n"):
  fprintf(fd, "}\n"):
  
  fclose(fd):

  for i from 1 to nops(required_mulsi) do
    printf("You need to provide a mpfr_mul_si%d function.\n", required_mulsi[i]):
    printf("  -> This can be achieved by a call to generate_muldivsin(\"mul\", %d):\n",  required_mulsi[i]):
  od:
  for i from 1 to nops(required_divsi) do
    printf("You need to provide a mpfr_div_si%d function.\n", required_divsi[i]):
    printf("  -> This can be achieved by a call to generate_muldivsin(\"div\", %d):\n",  required_divsi[i]):
  od:


  ######################################################
  ################## Error analysis ####################
  ######################################################
  
  printf("\n\n"):
  printf("Before the loop, we have "):
  for i from 1 to nc do
    var := sprintf("tip%d", init_cond[i][1]):
    printf("%s {%d}", var, find_in_error_counter(var, error_counter)):
    if (i <> nc) then printf(", ") else printf("\n") fi:
  od:
  printf("Each step of the loop adds another {%d}\n", error_in_loop):
  if (additional_error <> 0)
  then printf("Moreover, the multiplication by %a adds another {%d} to each term before it is summed.\n", subs(n=k, s2/s1), additional_error)
  fi:
  printf("Finally, we have s = sum_(i=0)^(k-1) ( ti{%d + %dk} )\n", maxofti + additional_error + 1 - error_in_loop, error_in_loop):
  printf("We bound it by {(k+%d)*2^(%d)}\n", ceil( (maxofti + additional_error + 1 - error_in_loop)/error_in_loop), ceil(log[2](error_in_loop))):

  a := ceil( (maxofti + additional_error + 1 - error_in_loop)/error_in_loop):
  b := ceil(log[2](error_in_loop)):

  if (a > 0)
    then var := sprintf("MPFR_INT_CEIL_LOG2 (prec + %d)", a)
    elif (a=0) then  var := sprintf("MPFR_INT_CEIL_LOG2 (prec)")
    else sprintf("MPFR_INT_CEIL_LOG2 (prec - %d)", -a)
  fi:
  if (b > 0) then var := sprintf("%s + %d", var, b+2) fi:
  var := sprintf("sed -n -i 's/ERRORANALYSISPREC/%s/g;p' %s", var, filename):
  system(var):

  if (a > 0)
    then var := sprintf("MPFR_INT_CEIL_LOG2 (k + %d)", a)
    elif (a=0) then  var := sprintf("MPFR_INT_CEIL_LOG2 (k)")
    else sprintf("MPFR_INT_CEIL_LOG2 (k - %d)", -a)
  fi:
  if (b > 0) then var := sprintf("%s + %d", var, b+2) fi:
  var := sprintf("sed -n -i 's/ERRORANALYSISK/%s/g;p' %s", var, filename):
  system(var):

  if (a > 0)
    then var := sprintf("MPFR_INT_CEIL_LOG2 (k + %d)", a)
    elif (a=0) then  var := sprintf("MPFR_INT_CEIL_LOG2 (k)")
    else sprintf("MPFR_INT_CEIL_LOG2 (k - %d)", -a)
  fi:
  var := sprintf("%s + %d", var, b+4):
  var := sprintf("sed -n -i 's/ERRORANALYSIS4K/%s/g;p' %s", var, filename):
  system(var):

end proc:
