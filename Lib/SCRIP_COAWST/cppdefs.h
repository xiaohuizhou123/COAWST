/*
** cppdefs.h for Lib/SCRIP_COAWST sources.
**
** Shadowing ROMS/Include/cppdefs.h (an #include "..." searches this
** directory first).  Two build paths use these sources:
**
**   1. ROMS/COAWST coupled build (root makefile): always passes -DSANDY,
**      so define the two macros these sources used to inherit from the
**      real cppdefs.h chain (sandy.h: NESTING, globaldefs.h: SCRIP_COAWST).
**      SCRIP_COAWST selects the "subroutine scrip_coawst" variant that
**      libROMS.a must provide (read_coawst_par calls it).
**
**   2. Standalone scrip_coawst weight tool (run_sandy_test.sh prep):
**      no -DSANDY -> both undefined -> "program scrip_coawst" main
**      variant, which is required for the executable to link (MAIN__).
**
** The sources otherwise only test MPI, supplied via -DMPI in both paths.
*/
#ifdef SANDY
# define NESTING
# define SCRIP_COAWST
#endif
