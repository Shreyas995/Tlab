#include "types.h"
#include "dns_error.h"
#include "dns_const.h"
#include "avgij_map.h"

#ifdef USE_MPI
#include "dns_const_mpi.h"
#endif

SUBROUTINE DNS_READ_LOCAL(inifile)

  USE TLAB_TYPES,     ONLY : MAX_MODES
  USE TLAB_CONSTANTS, ONLY : efile, lfile, wfile, MAX_PROF
  USE TLAB_VARS,    ONLY : pbg, rbg, damkohler
  USE TLAB_VARS,    ONLY : imax,jmax,kmax, isize_txc_field, isize_wrk1d,isize_wrk2d,isize_wrk3d
  USE TLAB_VARS,    ONLY : inb_flow,inb_scal,inb_txc
  USE TLAB_VARS,    ONLY : imode_sim, imode_eqns, imode_ibm, iadvection, iviscous, itransport, istagger
  USE TLAB_VARS,    ONLY : g
  USE TLAB_VARS,    ONLY : FilterDomain
  USE TLAB_VARS,    ONLY : nstatavg
  USE TLAB_PROCS
  USE THERMO_VARS, ONLY : imixture
  USE PARTICLE_VARS
  USE DNS_LOCAL
  USE TIME,          ONLY : rkm_mode, dtime, cfla, cfld, cflr
  USE BOUNDARY_BUFFER
  USE BOUNDARY_BCS
  USE BOUNDARY_INFLOW
  USE STATISTICS
  USE PLANES

  IMPLICIT NONE

#include "integers.h"

  CHARACTER*(*) inifile

! -------------------------------------------------------------------
  CHARACTER*512 sRes
  CHARACTER*64 lstr
  CHARACTER*32 bakfile
  TINTEGER is,idummy,inb_scal_local1
  TREAL dummy(inb_flow+inb_scal+1)

  TINTEGER :: bcs_visc_imin, bcs_visc_imax
  TINTEGER :: bcs_visc_jmin, bcs_visc_jmax
  TINTEGER :: bcs_visc_kmin, bcs_visc_kmax

! ###################################################################
  bakfile = TRIM(ADJUSTL(inifile))//'.bak'

  CALL TLAB_WRITE_ASCII(lfile, 'Reading local input data.')

! ###################################################################
! Main Section
! ###################################################################
  CALL TLAB_WRITE_ASCII(bakfile, '#')
  CALL TLAB_WRITE_ASCII(bakfile, '#[Main]')
  CALL TLAB_WRITE_ASCII(bakfile, '#TimeOrder=<RungeKuttaExplicit3/RungeKuttaExplicit4/RungeKuttaDiffusion3>')
  CALL TLAB_WRITE_ASCII(bakfile, '#TimeStep=<value (used if CFL is negative)>')
  CALL TLAB_WRITE_ASCII(bakfile, '#TimeCFL=<value>')
  CALL TLAB_WRITE_ASCII(bakfile, '#TimeDiffusiveCFL=<value>')
  CALL TLAB_WRITE_ASCII(bakfile, '#TimeReactiveCFL=<value>')
  CALL TLAB_WRITE_ASCII(bakfile, '#TermDivergence=<none/remove>')
  CALL TLAB_WRITE_ASCII(bakfile, '#RhsMode=<split/combined/nonblocking>')

  CALL SCANINICHAR(bakfile, inifile, 'Main', 'TimeOrder', 'dummy', sRes)
  IF     ( TRIM(ADJUSTL(sRes)) .EQ. 'rungekuttaexplicit3'  ) THEN; rkm_mode = RKM_EXP3;           lstr = '0.6';
  ELSEIF ( TRIM(ADJUSTL(sRes)) .EQ. 'rungekuttaexplicit4'  ) THEN; rkm_mode = RKM_EXP4;           lstr = '1.2';
  ELSEIF ( TRIM(ADJUSTL(sRes)) .EQ. 'rungekuttadiffusion3' ) THEN; rkm_mode = RKM_IMP3_DIFFUSION; lstr = '0.6';
!  ELSEIF ( TRIM(ADJUSTL(sRes)) .EQ. 'rungekuttasource3'    ) THEN; rkm_mode = RKM_IMP3_SOURCE;
  ELSE
    CALL TLAB_WRITE_ASCII(efile, 'DNS_READ_LOCAL. Wrong TimeOrder option.')
    CALL TLAB_STOP(DNS_ERROR_RKORDER)
  ENDIF

 ! Default cfla value set in lstr while reading TimeOrder
  CALL SCANINIREAL(bakfile, inifile, 'Main', 'TimeCFL',          TRIM(ADJUSTL(lstr)), cfla )
  WRITE(lstr,*) C_025_R *cfla ! Default value for diffusive CFL
  CALL SCANINIREAL(bakfile, inifile, 'Main', 'TimeDiffusiveCFL', TRIM(ADJUSTL(lstr)), cfld )
  WRITE(lstr,*) C_05_R  *cfla ! Default value for reactive CFL
  CALL SCANINIREAL(bakfile, inifile, 'Main', 'TimeReactiveCFL',  TRIM(ADJUSTL(lstr)), cflr )
  CALL SCANINIREAL(bakfile, inifile, 'Main', 'TimeStep', '0.05', dtime)

! -------------------------------------------------------------------
  CALL SCANINICHAR(bakfile, inifile, 'Main', 'TermDivergence', 'remove', sRes)
  IF      ( TRIM(ADJUSTL(sRes)) .eq. 'none'   ) THEN; idivergence = EQNS_NONE
  ELSE IF ( TRIM(ADJUSTL(sRes)) .eq. 'remove' ) THEN; idivergence = EQNS_DIVERGENCE
  ELSE
     CALL TLAB_WRITE_ASCII(efile, 'DNS_READ_LOCAL. Wrong TermDivergence option.')
     CALL TLAB_STOP(DNS_ERROR_OPTION)
  ENDIF

  CALL SCANINICHAR(bakfile, inifile, 'Main', 'RhsMode', 'combined', sRes)
  IF      ( TRIM(ADJUSTL(sRes)) .eq. 'split'       ) THEN; imode_rhs = EQNS_RHS_SPLIT
  ELSE IF ( TRIM(ADJUSTL(sRes)) .eq. 'combined'    ) THEN; imode_rhs = EQNS_RHS_COMBINED
#ifdef USE_PSFFT
  ELSE IF ( TRIM(ADJUSTL(sRes)) .eq. 'nonblocking' ) THEN; imode_rhs = EQNS_RHS_NONBLOCKING
#endif
  ELSE
     CALL TLAB_WRITE_ASCII(efile, 'DNS_READ_LOCAL. Wrong RhsMode option.')
     CALL TLAB_STOP(DNS_ERROR_OPTION)
  ENDIF

! ###################################################################
! Iteration Section
! ###################################################################
  CALL TLAB_WRITE_ASCII(bakfile, '#')
  CALL TLAB_WRITE_ASCII(bakfile, '#[Iteration]')
  CALL TLAB_WRITE_ASCII(bakfile, '#Start=<integral start time>')
  CALL TLAB_WRITE_ASCII(bakfile, '#End=<integral stop time>')
  CALL TLAB_WRITE_ASCII(bakfile, '#Restart=<restart time step>')
  CALL TLAB_WRITE_ASCII(bakfile, '#Statistics=<statistics time step>')
  CALL TLAB_WRITE_ASCII(bakfile, '#IteraLog=<value>')
  CALL TLAB_WRITE_ASCII(bakfile, '#Saveplanes=<value>')
  CALL TLAB_WRITE_ASCII(bakfile, '#RunAvera=<yes/no>')

  CALL SCANINIINT(bakfile, inifile, 'Iteration', 'Start',      '0',  nitera_first)
  CALL SCANINIINT(bakfile, inifile, 'Iteration', 'End',        '0',  nitera_last )
  CALL SCANINIINT(bakfile, inifile, 'Iteration', 'Restart',    '50', nitera_save )
  CALL SCANINIINT(bakfile, inifile, 'Iteration', 'Statistics', '50', nitera_stats)
  CALL SCANINIINT(bakfile, inifile, 'Iteration', 'IteraLog',   '10', nitera_log  )
  CALL SCANINIINT(bakfile, inifile, 'Iteration', 'Saveplanes', '-1', nitera_pln  )

! Accumulate statistics in spatial mode
  CALL SCANINIINT(bakfile, inifile, 'Iteration', 'SaveStats', '-1', nitera_stats_spa)

! Domain Filter (Should we move it to Iteration?)
  CALL SCANINIINT(bakfile, inifile, 'Filter', 'Step', '0', nitera_filter)
  IF ( nitera_filter .EQ. 0 ) FilterDomain(:)%type = DNS_FILTER_NONE

! ###################################################################
! Control Limits
! ###################################################################
  CALL TLAB_WRITE_ASCII(bakfile, '#')
  CALL TLAB_WRITE_ASCII(bakfile, '#[Control]')
  CALL TLAB_WRITE_ASCII(bakfile, '#FlowLimit=<yes/no>')
  CALL TLAB_WRITE_ASCII(bakfile, '#MinPressure=<pressure>')
  CALL TLAB_WRITE_ASCII(bakfile, '#MaxPressure=<pressure>')
  CALL TLAB_WRITE_ASCII(bakfile, '#MinDensity=<density>')
  CALL TLAB_WRITE_ASCII(bakfile, '#MaxDensity=<density>')
  CALL TLAB_WRITE_ASCII(bakfile, '#ScalLimit=<yes/no>')
  CALL TLAB_WRITE_ASCII(bakfile, '#MinScalar=<scalar>')
  CALL TLAB_WRITE_ASCII(bakfile, '#MaxScalar=<scalar>')

  bound_r%active = .false.
  bound_p%active = .false.
  CALL SCANINICHAR(bakfile, inifile, 'Control', 'FlowLimit', 'yes', sRes)
  IF ( TRIM(ADJUSTL(sRes)) .eq. 'yes' ) THEN
    bound_r%active = .true.
    bound_p%active = .true.
  ENDIF
! Final check in last section of the routine
  CALL SCANINIREAL(bakfile, inifile, 'Control', 'MinPressure', '-1.0', bound_p%min)
  CALL SCANINIREAL(bakfile, inifile, 'Control', 'MaxPressure', '-1.0', bound_p%max)
  CALL SCANINIREAL(bakfile, inifile, 'Control', 'MinDensity',  '-1.0', bound_r%min)
  CALL SCANINIREAL(bakfile, inifile, 'Control', 'MaxDensity',  '-1.0', bound_r%max)

  bound_d%active = .false.
  IF ( imode_eqns .EQ. DNS_EQNS_INCOMPRESSIBLE .OR. imode_eqns .EQ. DNS_EQNS_ANELASTIC ) THEN
    bound_d%active = .true.
    bound_d%max = C_BIG_R ! default
    CALL SCANINICHAR(bakfile, inifile, 'Control', 'MaxDilatation', 'void', sRes)
    IF ( TRIM(ADJUSTL(sRes)) .NE. 'void' ) THEN
        idummy = 1
        CALL LIST_REAL(sRes, idummy, dummy)
        bound_d%max = dummy(1)
    ENDIF
  ENDIF

  bound_s(:)%active = .false.
  CALL SCANINICHAR(bakfile, inifile, 'Control', 'ScalLimit', 'yes', sRes)
  IF ( TRIM(ADJUSTL(sRes)) .EQ. 'yes' ) THEN
    bound_s(:)%active = .true.
  ENDIF

  bound_s(:)%min = C_0_R; inb_scal_local1 = MAX_NSP
  if ( any(bound_s(:)%active ) ) then
    CALL SCANINICHAR(bakfile, inifile, 'Control', 'MinScalar',  'void', sRes)
     IF ( TRIM(ADJUSTL(sRes)) .NE. 'void' ) THEN
        CALL LIST_REAL(sRes, inb_scal_local1, dummy)
        IF ( inb_scal_local1 .NE. inb_scal ) THEN ! Consistency check
           CALL TLAB_WRITE_ASCII(efile,'DNS_READ_LOCAL. MinScalar size does not match inb_scal.')
           CALL TLAB_STOP(DNS_ERROR_OPTION)
        ELSE
            bound_s(1:inb_scal)%min = dummy(1:inb_scal)
        ENDIF
     ENDIF
  ENDIF

  bound_s%max = C_1_R; inb_scal_local1 = MAX_NSP
  if ( any(bound_s(:)%active) ) then
    CALL SCANINICHAR(bakfile, inifile, 'Control', 'MaxScalar',  'void', sRes)
     IF ( TRIM(ADJUSTL(sRes)) .NE. 'void' ) THEN
        CALL LIST_REAL(sRes, inb_scal_local1, dummy)
        IF ( inb_scal_local1 .NE. inb_scal ) THEN ! Consistency check
           CALL TLAB_WRITE_ASCII(efile,'DNS_READ_LOCAL. MaxScalar size does not match inb_scal.')
           CALL TLAB_STOP(DNS_ERROR_OPTION)
        ELSE
            bound_s(1:inb_scal)%max = dummy(1:inb_scal)
        ENDIF
     ENDIF
  ENDIF

! ###################################################################
! Boundary Conditions
! ###################################################################
  CALL TLAB_WRITE_ASCII(bakfile, '#')
  CALL TLAB_WRITE_ASCII(bakfile, '#[BoundaryConditions]')
  CALL TLAB_WRITE_ASCII(bakfile, '#ScalarImin=<none/dirichlet/neumman>')
  CALL TLAB_WRITE_ASCII(bakfile, '#ScalarJmin=<none/dirichlet/neumman>')
  CALL TLAB_WRITE_ASCII(bakfile, '#ScalarSfcTypeJmin=<static/linear>')
  CALL TLAB_WRITE_ASCII(bakfile, '#ScalarSfcTypeJmax=<static/linear>')
  CALL TLAB_WRITE_ASCII(bakfile, '#ScalarCouplingJmin=<value>')
  CALL TLAB_WRITE_ASCII(bakfile, '#ScalarCouplingJmax=<value>')
  CALL TLAB_WRITE_ASCII(bakfile, '#ScalarKmin=<none/dirichlet/neumman>')
  CALL TLAB_WRITE_ASCII(bakfile, '#VelocityImin=<none/dirichlet/neumman>')
  CALL TLAB_WRITE_ASCII(bakfile, '#VelocityJmin=<none/dirichlet/neumman>')
  CALL TLAB_WRITE_ASCII(bakfile, '#VelocityKmin=<none/dirichlet/neumman>')
  CALL TLAB_WRITE_ASCII(bakfile, '#ViscousI=<none/inflow/outflow>')
  CALL TLAB_WRITE_ASCII(bakfile, '#ViscousJ=<none/inflow/outflow>')
  CALL TLAB_WRITE_ASCII(bakfile, '#ViscousK=<none/inflow/outflow>')
  CALL TLAB_WRITE_ASCII(bakfile, '#SigmaOut=<value>')
  CALL TLAB_WRITE_ASCII(bakfile, '#SigmaInf=<value>')
  CALL TLAB_WRITE_ASCII(bakfile, '#BetaTransverse=<value>')

! -------------------------------------------------------------------
! Scalar terms (including surface model at vertical boundaries)
! -------------------------------------------------------------------
  BcsScalImin%type(:) = DNS_BCS_NONE; BcsScalImax%type(:) = DNS_BCS_NONE
  IF ( .NOT. g(1)%periodic ) THEN
  DO is = 1,inb_scal
     WRITE(lstr,*) is; lstr='Scalar'//TRIM(ADJUSTL(lstr))//'Imin'
     CALL SCANINICHAR(bakfile, inifile, 'BoundaryConditions', TRIM(ADJUSTL(lstr)), 'none', sRes)
     IF      ( TRIM(ADJUSTL(sRes)) .eq. 'none'      ) THEN; BcsScalImin%type(is) = DNS_BCS_NONE
     ELSE IF ( TRIM(ADJUSTL(sRes)) .eq. 'dirichlet' ) THEN; BcsScalImin%type(is) = DNS_BCS_DIRICHLET
     ELSE IF ( TRIM(ADJUSTL(sRes)) .eq. 'neumann'   ) THEN; BcsScalImin%type(is) = DNS_BCS_NEUMANN
     ELSE
        CALL TLAB_WRITE_ASCII(efile, 'DNS_READ_LOCAL. BoundaryConditions.'//TRIM(ADJUSTL(lstr)))
        CALL TLAB_STOP(DNS_ERROR_IBC)
     ENDIF
     WRITE(lstr,*) is; lstr='Scalar'//TRIM(ADJUSTL(lstr))//'Imax'
     CALL SCANINICHAR(bakfile, inifile, 'BoundaryConditions', TRIM(ADJUSTL(lstr)), 'none', sRes)
     IF      ( TRIM(ADJUSTL(sRes)) .eq. 'none'      ) THEN; BcsScalImax%type(is) = DNS_BCS_NONE
     ELSE IF ( TRIM(ADJUSTL(sRes)) .eq. 'dirichlet' ) THEN; BcsScalImax%type(is) = DNS_BCS_DIRICHLET
     ELSE IF ( TRIM(ADJUSTL(sRes)) .eq. 'neumann'   ) THEN; BcsScalImax%type(is) = DNS_BCS_NEUMANN
     ELSE
        CALL TLAB_WRITE_ASCII(efile, 'DNS_READ_LOCAL. BoundaryConditions.'//TRIM(ADJUSTL(lstr)))
        CALL TLAB_STOP(DNS_ERROR_IBC)
     ENDIF
  ENDDO
  ENDIF

  BcsScalJmin%type(:) = DNS_BCS_NONE; BcsScalJmax%type(:) = DNS_BCS_NONE
  IF ( .NOT. g(2)%periodic ) THEN
  DO is = 1,inb_scal
     !
     WRITE(lstr,*) is; lstr='Scalar'//TRIM(ADJUSTL(lstr))//'Jmin'
     CALL SCANINICHAR(bakfile, inifile, 'BoundaryConditions', TRIM(ADJUSTL(lstr)), 'void', sRes)
     IF      ( TRIM(ADJUSTL(sRes)) .eq. 'none'      ) THEN; BcsScalJmin%type(is) = DNS_BCS_NONE
     ELSE IF ( TRIM(ADJUSTL(sRes)) .eq. 'dirichlet' ) THEN; BcsScalJmin%type(is) = DNS_BCS_DIRICHLET
     ELSE IF ( TRIM(ADJUSTL(sRes)) .eq. 'neumann'   ) THEN; BcsScalJmin%type(is) = DNS_BCS_NEUMANN
     ELSE
        CALL TLAB_WRITE_ASCII(efile, 'DNS_READ_LOCAL. BoundaryConditions.'//TRIM(ADJUSTL(lstr)))
        CALL TLAB_STOP(DNS_ERROR_JBC)
     ENDIF
     WRITE(lstr,*) is; lstr='Scalar'//TRIM(ADJUSTL(lstr))//'SfcTypeJmin'
     CALL SCANINICHAR(bakfile, inifile, 'BoundaryConditions', TRIM(ADJUSTL(lstr)), 'static', sRes)
     IF ( sRes .eq. 'static' ) THEN
        BcsScalJmin%SfcType(is) = DNS_SFC_STATIC
     ELSEIF (sRes .eq. 'linear' ) THEN
        BcsScalJmin%SfcType(is) = DNS_SFC_LINEAR
     ELSE
        CALL TLAB_WRITE_ASCII(efile, 'DNS_READ_LOCAL. BoundaryConditions.'//TRIM(ADJUSTL(lstr)))
        CALL TLAB_STOP(DNS_ERROR_JBC)
     ENDIF
     WRITE(lstr,*) is; lstr='Scalar'//TRIM(ADJUSTL(lstr))//'CouplingJmin'
     CALL SCANINIREAL(bakfile, inifile, 'BoundaryConditions', TRIM(ADJUSTL(lstr)), '0.0', BcsScalJmin%cpl(is))
     !
     WRITE(lstr,*) is; lstr='Scalar'//TRIM(ADJUSTL(lstr))//'Jmax'
     CALL SCANINICHAR(bakfile, inifile, 'BoundaryConditions', TRIM(ADJUSTL(lstr)), 'void', sRes)
     IF      ( TRIM(ADJUSTL(sRes)) .eq. 'none'      ) THEN; BcsScalJmax%type(is) = DNS_BCS_NONE
     ELSE IF ( TRIM(ADJUSTL(sRes)) .eq. 'dirichlet' ) THEN; BcsScalJmax%type(is) = DNS_BCS_DIRICHLET
     ELSE IF ( TRIM(ADJUSTL(sRes)) .eq. 'neumann'   ) THEN; BcsScalJmax%type(is) = DNS_BCS_NEUMANN
     ELSE
        CALL TLAB_WRITE_ASCII(efile, 'DNS_READ_LOCAL. BoundaryConditions.'//TRIM(ADJUSTL(lstr)))
        CALL TLAB_STOP(DNS_ERROR_JBC)
     ENDIF
     WRITE(lstr,*) is; lstr='Scalar'//TRIM(ADJUSTL(lstr))//'SfcTypeJmax'
     CALL SCANINICHAR(bakfile, inifile, 'BoundaryConditions', TRIM(ADJUSTL(lstr)), 'static', sRes)
     IF ( sRes .eq. 'static' ) THEN
        BcsScalJmax%SfcType(is) = DNS_SFC_STATIC
     ELSEIF (sRes .eq. 'linear' ) THEN
        BcsScalJmax%SfcType(is) = DNS_SFC_LINEAR
     ELSE
        CALL TLAB_WRITE_ASCII(efile, 'DNS_READ_LOCAL. BoundaryConditions.'//TRIM(ADJUSTL(lstr)))
        CALL TLAB_STOP(DNS_ERROR_JBC)
     ENDIF
     WRITE(lstr,*) is; lstr='Scalar'//TRIM(ADJUSTL(lstr))//'CouplingJmax'
     CALL SCANINIREAL(bakfile, inifile, 'BoundaryConditions', TRIM(ADJUSTL(lstr)), '0.0', BcsScalJmax%cpl(is))
  ENDDO
  ENDIF

  BcsScalKmin%type(:) = DNS_BCS_NONE; BcsScalKmax%type(:) = DNS_BCS_NONE
  IF ( .NOT. g(3)%periodic ) THEN
  DO is = 1,inb_scal
     WRITE(lstr,*) is; lstr='Scalar'//TRIM(ADJUSTL(lstr))//'Kmin'
     CALL SCANINICHAR(bakfile, inifile, 'BoundaryConditions', TRIM(ADJUSTL(lstr)), 'none', sRes)
     IF      ( TRIM(ADJUSTL(sRes)) .eq. 'none'      ) THEN; BcsScalKmin%type(is) = DNS_BCS_NONE
     ELSE IF ( TRIM(ADJUSTL(sRes)) .eq. 'dirichlet' ) THEN; BcsScalKmin%type(is) = DNS_BCS_DIRICHLET
     ELSE IF ( TRIM(ADJUSTL(sRes)) .eq. 'neumann'   ) THEN; BcsScalKmin%type(is) = DNS_BCS_NEUMANN
     ELSE
        CALL TLAB_WRITE_ASCII(efile, 'DNS_READ_LOCAL. BoundaryConditions.'//TRIM(ADJUSTL(lstr)))
        CALL TLAB_STOP(DNS_ERROR_KBC)
     ENDIF
     WRITE(lstr,*) is; lstr='Scalar'//TRIM(ADJUSTL(lstr))//'Kmax'
     CALL SCANINICHAR(bakfile, inifile, 'BoundaryConditions', TRIM(ADJUSTL(lstr)), 'none', sRes)
     IF      ( TRIM(ADJUSTL(sRes)) .eq. 'none'      ) THEN; BcsScalKmax%type(is) = DNS_BCS_NONE
     ELSE IF ( TRIM(ADJUSTL(sRes)) .eq. 'dirichlet' ) THEN; BcsScalKmax%type(is) = DNS_BCS_DIRICHLET
     ELSE IF ( TRIM(ADJUSTL(sRes)) .eq. 'neumann'   ) THEN; BcsScalKmax%type(is) = DNS_BCS_NEUMANN
     ELSE
        CALL TLAB_WRITE_ASCII(efile, 'DNS_READ_LOCAL. BoundaryConditions.'//TRIM(ADJUSTL(lstr)))
        CALL TLAB_STOP(DNS_ERROR_KBC)
     ENDIF
  ENDDO
  ENDIF

! -------------------------------------------------------------------
! Velocity terms / Euler part in compressible mode
! -------------------------------------------------------------------
  CALL SCANINICHAR(bakfile, inifile, 'BoundaryConditions', 'VelocityImin', 'freeslip', sRes)
  IF      ( TRIM(ADJUSTL(sRes)) .eq. 'none'     ) THEN; BcsFlowImin%type(1:3) = DNS_BCS_NONE
  ELSE IF ( TRIM(ADJUSTL(sRes)) .eq. 'noslip'   ) THEN; BcsFlowImin%type(1:3) = DNS_BCS_DIRICHLET
  ELSE IF ( TRIM(ADJUSTL(sRes)) .eq. 'freeslip' ) THEN; BcsFlowImin%type(1)   = DNS_BCS_DIRICHLET
                                                        BcsFlowImin%type(2)   = DNS_BCS_NEUMANN
                                                        BcsFlowImin%type(3)   = DNS_BCS_NEUMANN
  ELSE
     CALL TLAB_WRITE_ASCII(efile, 'DNS_READ_LOCAL. BoundaryConditions.VelocityImin.')
     CALL TLAB_STOP(DNS_ERROR_IBC)
  ENDIF
  CALL SCANINICHAR(bakfile, inifile, 'BoundaryConditions', 'VelocityImax', 'freeslip', sRes)
  IF      ( TRIM(ADJUSTL(sRes)) .eq. 'none'     ) THEN; BcsFlowImax%type(1:3) = DNS_BCS_NONE
  ELSE IF ( TRIM(ADJUSTL(sRes)) .eq. 'noslip'   ) THEN; BcsFlowImax%type(1:3) = DNS_BCS_DIRICHLET
  ELSE IF ( TRIM(ADJUSTL(sRes)) .eq. 'freeslip' ) THEN; BcsFlowImax%type(1)   = DNS_BCS_DIRICHLET
                                                        BcsFlowImax%type(2)   = DNS_BCS_NEUMANN
                                                        BcsFlowImax%type(3)   = DNS_BCS_NEUMANN
  ELSE
     CALL TLAB_WRITE_ASCII(efile, 'DNS_READ_LOCAL. BoundaryConditions.VelocityImax.')
     CALL TLAB_STOP(DNS_ERROR_IBC)
  ENDIF

  CALL SCANINICHAR(bakfile, inifile, 'BoundaryConditions', 'VelocityJmin', 'freeslip', sRes)
  IF      ( TRIM(ADJUSTL(sRes)) .eq. 'none'     ) THEN; BcsFlowJmin%type(1:3) = DNS_BCS_NONE
  ELSE IF ( TRIM(ADJUSTL(sRes)) .eq. 'noslip'   ) THEN; BcsFlowJmin%type(1:3) = DNS_BCS_DIRICHLET
  ELSE IF ( TRIM(ADJUSTL(sRes)) .eq. 'freeslip' ) THEN; BcsFlowJmin%type(2)   = DNS_BCS_DIRICHLET
                                                        BcsFlowJmin%type(1)   = DNS_BCS_NEUMANN
                                                        BcsFlowJmin%type(3)   = DNS_BCS_NEUMANN
  ELSE
     CALL TLAB_WRITE_ASCII(efile, 'DNS_READ_LOCAL. BoundaryConditions.VelocityJmin.')
     CALL TLAB_STOP(DNS_ERROR_JBC)
  ENDIF
  CALL SCANINICHAR(bakfile, inifile, 'BoundaryConditions', 'VelocityJmax', 'freeslip', sRes)
  IF      ( TRIM(ADJUSTL(sRes)) .eq. 'none'     ) THEN; BcsFlowJmax%type(1:3) = DNS_BCS_NONE
  ELSE IF ( TRIM(ADJUSTL(sRes)) .eq. 'noslip'   ) THEN; BcsFlowJmax%type(1:3) = DNS_BCS_DIRICHLET
  ELSE IF ( TRIM(ADJUSTL(sRes)) .eq. 'freeslip' ) THEN; BcsFlowJmax%type(2)   = DNS_BCS_DIRICHLET
                                                        BcsFlowJmax%type(1)   = DNS_BCS_NEUMANN
                                                        BcsFlowJmax%type(3)   = DNS_BCS_NEUMANN
  ELSE
     CALL TLAB_WRITE_ASCII(efile, 'DNS_READ_LOCAL. BoundaryConditions.VelocityJmax.')
     CALL TLAB_STOP(DNS_ERROR_JBC)
  ENDIF

  CALL SCANINICHAR(bakfile, inifile, 'BoundaryConditions', 'VelocityKmin', 'freeslip', sRes)
  IF      ( TRIM(ADJUSTL(sRes)) .eq. 'none'     ) THEN; BcsFlowKmin%type(1:3) = DNS_BCS_NONE
  ELSE IF ( TRIM(ADJUSTL(sRes)) .eq. 'noslip'   ) THEN; BcsFlowKmin%type(1:3) = DNS_BCS_DIRICHLET
  ELSE IF ( TRIM(ADJUSTL(sRes)) .eq. 'freeslip' ) THEN; BcsFlowKmin%type(3)   = DNS_BCS_DIRICHLET
                                                        BcsFlowKmin%type(2)   = DNS_BCS_NEUMANN
                                                        BcsFlowKmin%type(1)   = DNS_BCS_NEUMANN
  ELSE
     CALL TLAB_WRITE_ASCII(efile, 'DNS_READ_LOCAL. BoundaryConditions.VelocityKmin.')
     CALL TLAB_STOP(DNS_ERROR_KBC)
  ENDIF
  CALL SCANINICHAR(bakfile, inifile, 'BoundaryConditions', 'VelocityKmax', 'freeslip', sRes)
  IF      ( TRIM(ADJUSTL(sRes)) .eq. 'none'     ) THEN; BcsFlowKmax%type(1:3) = DNS_BCS_NONE
  ELSE IF ( TRIM(ADJUSTL(sRes)) .eq. 'noslip'   ) THEN; BcsFlowKmax%type(1:3) = DNS_BCS_DIRICHLET
  ELSE IF ( TRIM(ADJUSTL(sRes)) .eq. 'freeslip' ) THEN; BcsFlowKmax%type(3)   = DNS_BCS_DIRICHLET
                                                        BcsFlowKmax%type(2)   = DNS_BCS_NEUMANN
                                                        BcsFlowKmax%type(1)   = DNS_BCS_NEUMANN
  ELSE
     CALL TLAB_WRITE_ASCII(efile, 'DNS_READ_LOCAL. BoundaryConditions.VelocityKmax.')
     CALL TLAB_STOP(DNS_ERROR_KBC)
  ENDIF


! -------------------------------------------------------------------
! Viscous terms
! -------------------------------------------------------------------
  CALL SCANINICHAR(bakfile, inifile, 'BoundaryConditions', 'ViscousI', 'none', sRes)
  IF      ( TRIM(ADJUSTL(sRes)) .eq. 'none'    ) THEN; bcs_visc_imin = 0;  bcs_visc_imax = 0
  ELSE IF ( TRIM(ADJUSTL(sRes)) .eq. 'inflow'  ) THEN; bcs_visc_imin = 1;  bcs_visc_imax = 2
  ELSE IF ( TRIM(ADJUSTL(sRes)) .eq. 'outflow' ) THEN; bcs_visc_imin = 2;  bcs_visc_imax = 2
  ELSE
     CALL TLAB_WRITE_ASCII(efile, 'DNS_READ_LOCAL. BoundaryConditions.ViscousI.')
     CALL TLAB_STOP(DNS_ERROR_IVSICBC)
  ENDIF

  CALL SCANINICHAR(bakfile, inifile, 'BoundaryConditions', 'ViscousJ', 'none', sRes)
  IF      ( TRIM(ADJUSTL(sRes)) .eq. 'none'    ) THEN; bcs_visc_jmin = 0;  bcs_visc_jmax = 0
  ELSE IF ( TRIM(ADJUSTL(sRes)) .eq. 'inflow'  ) THEN; bcs_visc_jmin = 1;  bcs_visc_jmax = 2
  ELSE IF ( TRIM(ADJUSTL(sRes)) .eq. 'outflow' ) THEN; bcs_visc_jmin = 2;  bcs_visc_jmax = 2
  ELSE
     CALL TLAB_WRITE_ASCII(efile, 'DNS_READ_LOCAL. BoundaryConditions.ViscousJ.')
     CALL TLAB_STOP(DNS_ERROR_JVSICBC)
  ENDIF

  CALL SCANINICHAR(bakfile, inifile, 'BoundaryConditions', 'ViscousK', 'none', sRes)
  IF      ( TRIM(ADJUSTL(sRes)) .eq. 'none'    ) THEN; bcs_visc_kmin = 0;  bcs_visc_kmax = 0
  ELSE IF ( TRIM(ADJUSTL(sRes)) .eq. 'inflow'  ) THEN; bcs_visc_kmin = 1;  bcs_visc_kmax = 2
  ELSE IF ( TRIM(ADJUSTL(sRes)) .eq. 'outflow' ) THEN; bcs_visc_kmin = 2;  bcs_visc_kmax = 2
  ELSE
     CALL TLAB_WRITE_ASCII(efile, 'DNS_READ_LOCAL. BoundaryConditions.ViscousK.')
     CALL TLAB_STOP(DNS_ERROR_KVSICBC)
  ENDIF

! -------------------------------------------------------------------
! Relaxation coefficients towards reference values in characteristic formulation
! -------------------------------------------------------------------
  BcsDrift = .FALSE.

! Inflow terms
  CALL SCANINIREAL(bakfile, inifile, 'BoundaryConditions', 'SigmaInf', '-1.0', dummy(1))
  ! IF ( dummy(1) .LE. C_0_R ) THEN; dummy(1) = C_0_R
  ! ELSE;                            BcsDrift = .TRUE.; ENDIF
  IF ( dummy(1) .GE. C_0_R ) BcsDrift = .TRUE.
  BcsFlowImin%cinf = dummy(1); BcsFlowImax%cinf = dummy(1) ! so far, all of them the same
  BcsFlowJmin%cinf = dummy(1); BcsFlowJmax%cinf = dummy(1)
  BcsFlowKmin%cinf = dummy(1); BcsFlowKmax%cinf = dummy(1)
  BcsScalImin%cinf = dummy(1); BcsScalImax%cinf = dummy(1)
  BcsScalJmin%cinf = dummy(1); BcsScalJmax%cinf = dummy(1)
  BcsScalKmin%cinf = dummy(1); BcsScalKmax%cinf = dummy(1)

! Outflow terms
  CALL SCANINIREAL(bakfile, inifile, 'BoundaryConditions', 'SigmaOut', '-1.0', dummy(1))
  ! IF ( dummy(1) .LE. C_0_R ) THEN; dummy(1) = C_0_R
  ! ELSE;                            BcsDrift =  .TRUE.; ENDIF
  IF ( dummy(1) .GE. C_0_R ) BcsDrift = .TRUE.
  BcsFlowImin%cout = dummy(1); BcsFlowImax%cout = dummy(1) ! so far, all of them the same
  BcsFlowJmin%cout = dummy(1); BcsFlowJmax%cout = dummy(1)
  BcsFlowKmin%cout = dummy(1); BcsFlowKmax%cout = dummy(1)
  BcsScalImin%cout = dummy(1); BcsScalImax%cout = dummy(1)
  BcsScalJmin%cout = dummy(1); BcsScalJmax%cout = dummy(1)
  BcsScalKmin%cout = dummy(1); BcsScalKmax%cout = dummy(1)

! Transverse terms
  CALL SCANINIREAL(bakfile, inifile, 'BoundaryConditions', 'BetaTransverse', '-1.0', dummy(1))
  ! IF ( dummy(1) .LE. C_0_R ) THEN; dummy(1) = C_0_R
  ! ELSE;                            BcsDrift =  .TRUE.; ENDIF
  IF ( dummy(1) .GE. C_0_R ) BcsDrift = .TRUE.
  BcsFlowImin%ctan = dummy(1); BcsFlowImax%ctan = dummy(1) ! so far, all of them the same
  BcsFlowJmin%ctan = dummy(1); BcsFlowJmax%ctan = dummy(1)
  BcsFlowKmin%ctan = dummy(1); BcsFlowKmax%ctan = dummy(1)
  BcsScalImin%ctan = dummy(1); BcsScalImax%ctan = dummy(1)
  BcsScalJmin%ctan = dummy(1); BcsScalJmax%ctan = dummy(1)
  BcsScalKmin%ctan = dummy(1); BcsScalKmax%ctan = dummy(1)

! ###################################################################
! IBM Status Parameter
! ###################################################################
  CALL TLAB_WRITE_ASCII(bakfile, '#')
  CALL TLAB_WRITE_ASCII(bakfile, '#[IBMParameter]')
  CALL TLAB_WRITE_ASCII(bakfile, '#Status=<on/off>')
  CALL SCANINICHAR(bakfile, inifile, 'IBMParameter', 'Status', 'off', sRes)
  IF      (TRIM(ADJUSTL(sRes)) == 'off') THEN; imode_ibm = 0
  ELSE IF (TRIM(ADJUSTL(sRes)) == 'on' ) THEN; imode_ibm = 1
  ELSE
    CALL TLAB_WRITE_ASCII(efile, 'DNS_READ_LOCAL. Wrong IBM Status option.')
    CALL TLAB_STOP(DNS_ERROR_OPTION)
  ENDIF

! ###################################################################
! Buffer Zone Parameters
! ###################################################################
  CALL TLAB_WRITE_ASCII(bakfile, '#')
  CALL TLAB_WRITE_ASCII(bakfile, '#')
  CALL TLAB_WRITE_ASCII(bakfile, '#[BufferZone]')
  CALL TLAB_WRITE_ASCII(bakfile, '#Type=<none/relaxation/filter/both>')
  CALL TLAB_WRITE_ASCII(bakfile, '#LoadBuffer=<yes/no>')
  CALL TLAB_WRITE_ASCII(bakfile, '#PointsJmin=<value>')
  CALL TLAB_WRITE_ASCII(bakfile, '#PointsJmax=<value>')
  CALL TLAB_WRITE_ASCII(bakfile, '#PointsImin=<value>')
  CALL TLAB_WRITE_ASCII(bakfile, '#PointsImax=<value>')
  CALL TLAB_WRITE_ASCII(bakfile, '#ParametersJmin=<values>')
  CALL TLAB_WRITE_ASCII(bakfile, '#ParametersJmax=<values>')
  CALL TLAB_WRITE_ASCII(bakfile, '#ParametersImin=<values>')
  CALL TLAB_WRITE_ASCII(bakfile, '#ParametersImax=<values>')
  CALL TLAB_WRITE_ASCII(bakfile, '#HardValuesJmin=<values>')
  CALL TLAB_WRITE_ASCII(bakfile, '#HardValuesJmax=<values>')
  CALL TLAB_WRITE_ASCII(bakfile, '#HardValuesImin=<values>')
  CALL TLAB_WRITE_ASCII(bakfile, '#HardValuesImax=<values>')

  CALL SCANINICHAR(bakfile, inifile, 'BufferZone', 'Type', 'none', sRes)
  IF      ( TRIM(ADJUSTL(sRes)) .EQ. 'none'       ) THEN; BuffType = DNS_BUFFER_NONE
  ELSE IF ( TRIM(ADJUSTL(sRes)) .EQ. 'relaxation' ) THEN; BuffType = DNS_BUFFER_RELAX
  ELSE IF ( TRIM(ADJUSTL(sRes)) .EQ. 'filter'     ) THEN; BuffType = DNS_BUFFER_FILTER
  ELSE IF ( TRIM(ADJUSTL(sRes)) .EQ. 'both'       ) THEN; BuffType = DNS_BUFFER_BOTH
  ELSE
     CALL TLAB_WRITE_ASCII(efile, 'DNS_READ_LOCAL. Wrong BufferType option.')
     CALL TLAB_STOP(DNS_ERROR_OPTION)
  ENDIF

! Load buffer if used also by BCs
  CALL SCANINICHAR(bakfile, inifile, 'BufferZone', 'LoadBuffer', 'no', sRes)
  IF ( TRIM(ADJUSTL(sRes)) .EQ. 'yes' ) THEN; BuffLoad = .TRUE.
  ELSE;                                       BuffLoad = .FALSE.
  ENDIF

! Sizes; read always because allocation checks if # points is zero
  CALL SCANINIINT(bakfile, inifile, 'BufferZone', 'PointsUImin', '0', BuffFlowImin%size)
  CALL SCANINIINT(bakfile, inifile, 'BufferZone', 'PointsUImax', '0', BuffFlowImax%size)
  CALL SCANINIINT(bakfile, inifile, 'BufferZone', 'PointsUJmin', '0', BuffFlowJmin%size)
  CALL SCANINIINT(bakfile, inifile, 'BufferZone', 'PointsUJmax', '0', BuffFlowJmax%size)

  CALL SCANINIINT(bakfile, inifile, 'BufferZone', 'PointsSImin', '0', BuffScalImin%size)
  CALL SCANINIINT(bakfile, inifile, 'BufferZone', 'PointsSImax', '0', BuffScalImax%size)
  CALL SCANINIINT(bakfile, inifile, 'BufferZone', 'PointsSJmin', '0', BuffScalJmin%size)
  CALL SCANINIINT(bakfile, inifile, 'BufferZone', 'PointsSJmax', '0', BuffScalJmax%size)

  BuffScalImin%type = BuffType; BuffFlowImin%type = BuffType ! So far, all the same
  BuffScalImax%type = BuffType; BuffFlowImax%type = BuffType
  BuffScalJmin%type = BuffType; BuffFlowJmin%type = BuffType
  BuffScalJmax%type = BuffType; BuffFlowJmax%type = BuffType

  IF ( BuffScalImin%size .NE. BuffFlowImin%size .OR. &
       BuffScalImax%size .NE. BuffFlowImax%size .OR. &
       BuffScalJmin%size .NE. BuffFlowJmin%size .OR. &
       BuffScalJmax%size .NE. BuffFlowJmax%size      ) THEN ! Because of io_subarray
     CALL TLAB_WRITE_ASCII(wfile, 'DNS_READ_LOCAL. Buffer zone sizes must be equal in flow and scal.')
     CALL TLAB_STOP(DNS_ERROR_OPTION)
  ENDIF

! Parameters
  IF ( BuffType .NE. DNS_BUFFER_NONE ) THEN
    CALL BOUNDARY_BUFFER_READBLOCK(bakfile,inifile,'UImin',BuffFlowImin,inb_flow)
    CALL BOUNDARY_BUFFER_READBLOCK(bakfile,inifile,'UImax',BuffFlowImax,inb_flow)
    CALL BOUNDARY_BUFFER_READBLOCK(bakfile,inifile,'UJmin',BuffFlowJmin,inb_flow)
    CALL BOUNDARY_BUFFER_READBLOCK(bakfile,inifile,'UJmax',BuffFlowJmax,inb_flow)
    CALL BOUNDARY_BUFFER_READBLOCK(bakfile,inifile,'SImin',BuffScalImin,inb_scal)
    CALL BOUNDARY_BUFFER_READBLOCK(bakfile,inifile,'SImax',BuffScalImax,inb_scal)
    CALL BOUNDARY_BUFFER_READBLOCK(bakfile,inifile,'SJmin',BuffScalJmin,inb_scal)
    CALL BOUNDARY_BUFFER_READBLOCK(bakfile,inifile,'SJmax',BuffScalJmax,inb_scal)
  ENDIF

! ###################################################################
! Viscosity Control
! ###################################################################
  CALL TLAB_WRITE_ASCII(bakfile, '#')
  CALL TLAB_WRITE_ASCII(bakfile, '#[ViscChange]')
  CALL TLAB_WRITE_ASCII(bakfile, '#Time=<time>')

  CALL SCANINIREAL(bakfile, inifile, 'ViscChange', 'Time', '0.0', visc_time)

! ###################################################################
! Save planes to disk
! ###################################################################
  CALL TLAB_WRITE_ASCII(bakfile, '#')
  CALL TLAB_WRITE_ASCII(bakfile, '#[SavePlanes]')
  CALL TLAB_WRITE_ASCII(bakfile, '#PlanesI=<value>')
  CALL TLAB_WRITE_ASCII(bakfile, '#PlanesJ=<value>')
  CALL TLAB_WRITE_ASCII(bakfile, '#PlanesK=<value>')

  CALL SCANINICHAR(bakfile, inifile, 'SavePlanes', 'PlanesI', 'void', sRes)
  IF ( TRIM(ADJUSTL(sRes)) .EQ. 'void'  ) THEN
     iplanes%n = 0; iplanes%nodes = 0
  ELSE
     iplanes%n = MAX_SAVEPLANES; CALL LIST_INTEGER(sRes, iplanes%n, iplanes%nodes)
  ENDIF

  CALL SCANINICHAR(bakfile, inifile, 'SavePlanes', 'PlanesJ', 'void', sRes)
  IF ( TRIM(ADJUSTL(sRes)) .EQ. 'void'  ) THEN
     jplanes%n = 0; jplanes%nodes = 0
  ELSE
     jplanes%n = MAX_SAVEPLANES; CALL LIST_INTEGER(sRes, jplanes%n, jplanes%nodes)
  ENDIF

  CALL SCANINICHAR(bakfile, inifile, 'SavePlanes', 'PlanesK', 'void', sRes)
  IF ( TRIM(ADJUSTL(sRes)) .EQ. 'void'  ) THEN
     kplanes%n = 0; kplanes%nodes = 0
  ELSE
     kplanes%n = MAX_SAVEPLANES; CALL LIST_INTEGER(sRes, kplanes%n, kplanes%nodes)
  ENDIF

! ###################################################################
! Save lines to disk
! ###################################################################
  CALL TLAB_WRITE_ASCII(bakfile, '#')
  CALL TLAB_WRITE_ASCII(bakfile, '#[SaveTowers]')
  CALL TLAB_WRITE_ASCII(bakfile, 'Stride=<value_i,value_j,value_k>')

  CALL SCANINICHAR(bakfile, inifile, 'SaveTowers', 'Stride', '0,0,0', sRes)
  idummy = 3; CALL LIST_INTEGER(sRes,idummy,tower_stride)
  IF ( idummy .NE. 3 ) THEN
     tower_stride(:) = 0
     CALL TLAB_WRITE_ASCII(bakfile, 'Stride=0,0,0')
     CALL TLAB_WRITE_ASCII(wfile,   'DNS_READ_LOCAL. Cannot read stride for towers; set to 0,0,0.')
  ENDIF

! ###################################################################
! Statistics Control
! ###################################################################
  CALL TLAB_WRITE_ASCII(bakfile, '#')
  CALL TLAB_WRITE_ASCII(bakfile, '#[Statsitics]')
  CALL TLAB_WRITE_ASCII(bakfile, '#Averages=<yes/no>')
  CALL TLAB_WRITE_ASCII(bakfile, '#Pdfs=<yes/no>')
  CALL TLAB_WRITE_ASCII(bakfile, '#ConditionalAverages=<yes/no>')
  CALL TLAB_WRITE_ASCII(bakfile, '#Intermittency=<yes/no>')

  CALL SCANINICHAR(bakfile, inifile, 'Statistics', 'Averages', 'yes', sRes)
  IF ( TRIM(ADJUSTL(sRes)) .EQ. 'yes' ) THEN; stats_averages = .TRUE.
  ELSE;                                       stats_averages = .FALSE.; ENDIF

  CALL SCANINICHAR(bakfile, inifile, 'Statistics', 'Pdfs', 'yes', sRes)
  IF ( TRIM(ADJUSTL(sRes)) .EQ. 'yes' ) THEN; stats_pdfs = .TRUE.
  ELSE;                                       stats_pdfs = .FALSE.; ENDIF

  CALL SCANINICHAR(bakfile, inifile, 'Statistics', 'Intermittency', 'yes', sRes)
  IF ( TRIM(ADJUSTL(sRes)) .EQ. 'yes' ) THEN; stats_intermittency = .TRUE.
  ELSE;                                       stats_intermittency = .FALSE.; ENDIF

! ###################################################################
! Inflow forcing conditions
! ###################################################################
  CALL TLAB_WRITE_ASCII(bakfile, '#')
  CALL TLAB_WRITE_ASCII(bakfile, '#[Inflow]')
  CALL TLAB_WRITE_ASCII(bakfile, '#Type=<None/Discrete/Broadband/Both>')
  CALL TLAB_WRITE_ASCII(bakfile, '#Adapt=<value>')
  CALL TLAB_WRITE_ASCII(bakfile, '#Imax=<imax>')
  CALL TLAB_WRITE_ASCII(bakfile, '#Jmax=<jmax>')
  CALL TLAB_WRITE_ASCII(bakfile, '#Kmax=<kmax>')

  CALL SCANINICHAR(bakfile, inifile, 'Inflow', 'Type', 'None', sRes)
  IF     ( TRIM(ADJUSTL(sRes)) .eq. 'none'                ) THEN; inflow_mode = 0
  ELSEIF ( TRIM(ADJUSTL(sRes)) .eq. 'discrete'            ) THEN; inflow_mode = 1
  ELSEIF ( TRIM(ADJUSTL(sRes)) .eq. 'broadbandperiodic'   ) THEN; inflow_mode = 2
  ELSEIF ( TRIM(ADJUSTL(sRes)) .eq. 'broadbandsequential' ) THEN; inflow_mode = 3
  ELSEIF ( TRIM(ADJUSTL(sRes)) .eq. 'both'                ) THEN; inflow_mode = 4
  ELSE
     CALL TLAB_WRITE_ASCII(efile, 'DNS_READ_LOCAL. Error in Inflow.Type.')
     CALL TLAB_STOP(DNS_ERROR_INFTYPE)
  ENDIF

  CALL SCANINIREAL(bakfile, inifile, 'Inflow', 'Adapt', '0.0', inflow_adapt)

! Broadband forcing: Grid size of the inflow domain
  g_inf(:)%size     = 1       ! default
  g_inf(:)%periodic = g(:)%periodic
  g_inf(:)%uniform  = g(:)%uniform
  IF ( inflow_mode .EQ. 2 .OR. inflow_mode .EQ. 3 .OR. inflow_mode .EQ. 4 ) THEN
     CALL SCANINIINT(bakfile, inifile, 'Inflow', 'Imax', '0', idummy)
     IF ( idummy .GT. 0         ) THEN; g_inf(1)%size = idummy
     ELSE
        CALL TLAB_WRITE_ASCII(efile, 'DNS_READ_LOCAL. Error in Inflow.Imax.')
        CALL TLAB_STOP(DNS_ERROR_INFTYPE)
     ENDIF

     CALL SCANINIINT(bakfile, inifile, 'Inflow', 'Jmax', '0', idummy)
     IF ( idummy .GT. 0         ) THEN; g_inf(2)%size = idummy
     ELSE
        CALL TLAB_WRITE_ASCII(efile, 'DNS_READ_LOCAL. Error in Inflow.Jmax.')
        CALL TLAB_STOP(DNS_ERROR_INFTYPE)
     ENDIF

     CALL SCANINIINT(bakfile, inifile, 'Inflow', 'Kmax', '0', idummy)
     IF ( idummy .EQ. g(3)%size ) THEN; g_inf(3)%size = idummy
     ELSE
        CALL TLAB_WRITE_ASCII(efile, 'DNS_READ_LOCAL. Error in Inflow.Kmax.')
        CALL TLAB_STOP(DNS_ERROR_INFTYPE)
     ENDIF

  ENDIF
  g_inf(1)%inb_grid = g(1)%inb_grid
  g_inf(2)%inb_grid = 1
  g_inf(3)%inb_grid = 1

  IF ( inflow_mode .EQ. 2 ) THEN
     g_inf(1)%periodic = .TRUE.
     g_inf(1)%uniform  = .TRUE.
  ENDIF

  idummy = MAX(g_inf(1)%size,MAX(g_inf(2)%size,g_inf(3)%size))
  isize_wrk1d = MAX(isize_wrk1d,idummy)

  idummy = MAX(g_inf(1)%size*g_inf(2)%size,MAX(g_inf(1)%size*g_inf(3)%size,g_inf(2)%size*g_inf(3)%size))
  isize_wrk2d = MAX(isize_wrk2d, idummy)

  ! -------------------------------------------------------------------
  ! Discrete Forcing
  ! -------------------------------------------------------------------
  call DISCRETE_READBLOCK(bakfile, inifile, 'Discrete', fp)
  ! Modulation type in fp%type; varicose or sinuous

  ! Parameter 1 is the y-thickness of the perturbation
  ! Parameter 2 is the x-length of the inflow domain

! ###################################################################
! Final initialization and control statements
! ###################################################################
  IF ( nitera_first .GT. nitera_last ) THEN
     CALL TLAB_WRITE_ASCII(efile, 'DNS_READ_LOCAL. Not started because nitera_first > nitera_last.' )
     CALL TLAB_STOP(DNS_ERROR_OPTION)
  END IF

! Avoid dividing by zero in time_integration routine
  IF ( nitera_save      .LE. 0 ) nitera_save      = nitera_last - nitera_first + 1
  IF ( nitera_stats     .LE. 0 ) nitera_stats     = nitera_last - nitera_first + 1
  IF ( nitera_log       .LE. 0 ) nitera_log       = nitera_last - nitera_first + 1
  IF ( nitera_pln       .LE. 0 ) nitera_pln       = nitera_last - nitera_first + 1
  IF ( nitera_filter .LE. 0 ) nitera_filter = nitera_last - nitera_first + 1

  IF ( imode_sim .EQ. DNS_MODE_TEMPORAL ) nitera_stats_spa =-1 ! Never call avg_spatial routines
  IF ( nitera_stats_spa .LE. 0 ) nitera_stats_spa = nitera_last - nitera_first + 1

! -------------------------------------------------------------------
! Control limits
! I need rbg%mean
! -------------------------------------------------------------------
  IF ( bound_p%min .LT. C_0_R ) bound_p%min = pbg%mean*C_1EM6_R
  IF ( bound_p%max .LT. C_0_R ) bound_p%max = pbg%mean/C_1EM6_R
  IF ( bound_r%min .LT. C_0_R ) bound_r%min = rbg%mean*C_1EM6_R
  IF ( bound_r%max .LT. C_0_R ) bound_r%max = rbg%mean/C_1EM6_R

! -------------------------------------------------------------------
! Boundary conditions
! -------------------------------------------------------------------
! Make sure periodic BCs are not modified
  IF ( g(1)%periodic ) THEN;
     BcsFlowImin%type(:)  = DNS_BCS_NONE; BcsFlowImax%type(:)  = DNS_BCS_NONE
     BcsScalImin%type(:)  = DNS_BCS_NONE; BcsScalImax%type(:)  = DNS_BCS_NONE
     bcs_visc_imin     = DNS_BCS_NONE; bcs_visc_imax     = DNS_BCS_NONE
  ENDIF
  IF ( g(2)%periodic ) THEN;
     BcsFlowJmin%type(:)  = DNS_BCS_NONE; BcsFlowJmax%type(:)  = DNS_BCS_NONE
     BcsScalJmin%type(:)  = DNS_BCS_NONE; BcsScalJmax%type(:)  = DNS_BCS_NONE
     bcs_visc_jmin     = DNS_BCS_NONE; bcs_visc_jmax     = DNS_BCS_NONE
  ENDIF
  IF ( g(3)%periodic ) THEN;
     BcsFlowKmin%type(:)  = DNS_BCS_NONE; BcsFlowKmax%type(:)  = DNS_BCS_NONE
     BcsScalKmin%type(:)  = DNS_BCS_NONE; BcsScalKmax%type(:)  = DNS_BCS_NONE
     bcs_visc_kmin     = DNS_BCS_NONE; bcs_visc_kmax     = DNS_BCS_NONE
  ENDIF

! BCs for OPR_PARTIAL at xmin (1,*) and xmax (2,*)
  bcs_inf = 0                                    ! default is biased non-zero; if 1, set to zero
  IF ( bcs_visc_imin .EQ. 1 ) bcs_inf(1,2,1) = 1 ! Inflow conditions
  IF ( bcs_visc_imax .EQ. 1 ) bcs_inf(2,2,1) = 1
  IF ( bcs_visc_jmin .EQ. 1 ) bcs_inf(1,2,2) = 1
  IF ( bcs_visc_jmax .EQ. 1 ) bcs_inf(2,2,2) = 1
  IF ( bcs_visc_kmin .EQ. 1 ) bcs_inf(1,2,3) = 1
  IF ( bcs_visc_kmax .EQ. 1 ) bcs_inf(2,2,3) = 1

  bcs_out = 0
  IF ( bcs_visc_imin .EQ. 2 ) bcs_out(1,2,1) = 1 ! Outflow conditions
  IF ( bcs_visc_imax .EQ. 2 ) bcs_out(2,2,1) = 1
  IF ( bcs_visc_jmin .EQ. 2 ) bcs_out(1,2,2) = 1
  IF ( bcs_visc_jmax .EQ. 2 ) bcs_out(2,2,2) = 1
  IF ( bcs_visc_kmin .EQ. 2 ) bcs_out(1,2,3) = 1
  IF ( bcs_visc_kmax .EQ. 2 ) bcs_out(2,2,3) = 1

! Make sure there is array space for reference mean drift
  IF ( BcsDrift ) THEN
     BuffFlowJmin%size = MAX(BuffFlowJmin%size,i1); BuffFlowJmax%size = MAX(BuffFlowJmax%size,i1)
     BuffScalJmin%size = BuffFlowJmin%size; BuffScalJmax%size = BuffFlowJmax%size
     IF ( imode_sim .EQ. DNS_MODE_SPATIAL  ) THEN
        BuffFlowImin%size = MAX(BuffFlowImin%size,i1); BuffFlowImax%size = MAX(BuffFlowImax%size,i1)
     ENDIF
     BuffScalImin%size = BuffFlowImin%size; BuffScalImax%size = BuffFlowImax%size
  ENDIF

! -------------------------------------------------------------------
! Interactive Boundary conditions
! -------------------------------------------------------------------
  DO is =1,inb_scal
     IF ( BcsScalJmin%type(is).NE. DNS_BCS_DIRICHLET .AND. &
          BcsScalJmin%SfcType(is) .NE. DNS_SFC_STATIC ) THEN
        CALL TLAB_WRITE_ASCII(efile, &
             'DNS_READ_LOCAL. Interactive BC at jmin not implemented for non-Dirichlet BC')
        CALL TLAB_STOP(DNS_ERROR_JBC)
     ENDIF
     IF ( BcsScalJmax%type(is).NE. DNS_BCS_DIRICHLET .AND. &
          BcsScalJmax%SfcType(is) .NE. DNS_SFC_STATIC ) THEN
        WRITE(*,*) BcsScalJmax%type(is), BcsScalJmax%SfcType(is), BcsScalJmax%cpl(is)
        CALL TLAB_WRITE_ASCII(efile, &
             'DNS_READ_LOCAL. Interactive BC at jmax not implemented for non-Dirichlet BC')
        CALL TLAB_STOP(DNS_ERROR_JBC)
     ENDIF
  ENDDO

! -------------------------------------------------------------------
! Implicit RKM part
! -------------------------------------------------------------------
  IF ( rkm_mode .EQ. RKM_IMP3_DIFFUSION ) THEN

! Check if Neumann BCs for scalar are present and warn if so
     DO is=1,inb_scal
        IF ( BcsScalJmin%type(is) .EQ. DNS_BCS_NEUMANN .OR. &
             BcsScalJmax%type(is) .EQ. DNS_BCS_NEUMANN ) THEN
           WRITE(sRes, *) is; sRes='DNS_REAL_LOCAL. Scalar'//TRIM(ADJUSTL(sRes))//&
                ': Finite flux BC not implemented for SEMI-IMPLICITE DIFFUSION'
           CALL TLAB_WRITE_ASCII(wfile, TRIM(ADJUSTL(sRes)))
           WRITE(sRes, *) is; sRes='DNS_REAL_LOCAL. Scalar'//TRIM(ADJUSTL(sRes))//&
                ': Setting fluxes at boundary to zero'
           CALL TLAB_WRITE_ASCII(wfile, TRIM(ADJUSTL(sRes)))
        ENDIF
     ENDDO

! Check if grid is non-uniform
     IF ( .NOT. g(1)%uniform .AND. g(1)%mode_fdm .NE. FDM_COM6_DIRECT ) THEN
        CALL TLAB_WRITE_ASCII(efile, 'DNS_READ_LOCAL. Non-uniform grid requires a direct FDM formulation.')
        CALL TLAB_STOP(DNS_ERROR_UNDEVELOP)
     ENDIF

     IF ( imode_eqns /= DNS_EQNS_INCOMPRESSIBLE ) THEN
       CALL TLAB_WRITE_ASCII(efile, 'DNS_READ_LOCAL. Implicit formulation only available for incompressible case.')
       CALL TLAB_STOP(DNS_ERROR_UNDEVELOP)
    ENDIF

  ENDIF

! -------------------------------------------------------------------
! Towers information
! So far, the use or not use of tower information is
! set by the stride information.
! -------------------------------------------------------------------
  use_tower = .false.
  IF ( MINVAL(tower_stride).GT.0 ) THEN; use_tower=.true.; ENDIF

! We need space
  IF ( use_tower ) THEN
     idummy = tower_stride(1) *tower_stride(2) *tower_stride(3)
     IF ( idummy .LT. 5 ) THEN
        CALL TLAB_WRITE_ASCII(efile, 'DNS_READ_LOCAL. Not enough space in wrk3d array to handle tower information. Increase strides.')
        CALL TLAB_STOP(DNS_ERROR_UNDEVELOP)
     ENDIF
  ENDIF

! -------------------------------------------------------------------
! Pressure staggering
! -------------------------------------------------------------------
  IF ( istagger .EQ. 1 ) THEN
     IF ( .NOT. (imode_rhs == EQNS_RHS_COMBINED) ) THEN
        CALL TLAB_WRITE_ASCII(efile, 'DNS_READ_LOCAL. Horizontal pressure staggering only implemented for imode_rhs == EQNS_RHS_COMBINED.')
        CALL TLAB_STOP(DNS_ERROR_UNDEVELOP)
     ENDIF
 ENDIF

! -------------------------------------------------------------------
! Nonblocking formulation only valid for 2 scalars or less
! -------------------------------------------------------------------
  IF ( imode_rhs .EQ. EQNS_RHS_NONBLOCKING ) THEN
    IF ( inb_scal .GT. 2 ) THEN
       CALL TLAB_WRITE_ASCII(efile,&
            'DNS_READ_LOCAL. Nonblocking Communication not implemented >2 scalars' )
       CALL TLAB_STOP(DNS_ERROR_UNDEVELOP)
    ELSE IF ( inb_scal .LT. 1 ) THEN
       CALL TLAB_WRITE_ASCII(efile,&
            'DNS_READ_LOCAL. Nonblocking Communication require at least 1 scalar')
       CALL TLAB_STOP(DNS_ERROR_UNDEVELOP)
    ENDIF
  ENDIF

  ! -------------------------------------------------------------------
  ! Array sizes
  ! -------------------------------------------------------------------
  SELECT CASE ( imode_eqns )
  CASE( DNS_EQNS_INCOMPRESSIBLE,DNS_EQNS_ANELASTIC )
    inb_txc = 6
    IF ( rkm_mode == RKM_IMP3_DIFFUSION ) inb_txc = inb_txc+1
  CASE( DNS_EQNS_INTERNAL,DNS_EQNS_TOTAL)
    IF ( itransport .EQ. EQNS_TRANS_POWERLAW ) THEN
       CALL TLAB_WRITE_ASCII(efile,'RHS_SCAL_GLOBAL_2. Only constant viscosity.')
       CALL TLAB_STOP(DNS_ERROR_UNDEVELOP)
    ENDIF

    IF ( imode_eqns .EQ. DNS_EQNS_TOTAL ) THEN
       CALL TLAB_WRITE_ASCII(efile,'RHS_SCAL_GLOBAL_2. No total energy formulation.')
       CALL TLAB_STOP(DNS_ERROR_UNDEVELOP)
    ENDIF

    inb_txc = 9
    IF ( imode_eqns == DNS_EQNS_INTERNAL .AND. iadvection == EQNS_SKEWSYMMETRIC .AND. &
      iviscous   == EQNS_EXPLICIT ) inb_txc = 6
  END SELECT
  IF ( imixture == MIXT_TYPE_AIRWATER .AND. damkohler(3) > C_0_R ) inb_txc = inb_txc + 1

  IF ( imode_sim == DNS_MODE_SPATIAL ) THEN ! because of the statistics
    inb_txc = MAX(inb_txc,7)

    IF ( stats_averages ) THEN
      idummy = MAX(MA_MOMENTUM_SIZE,MS_SCALAR_SIZE)
      IF ( MOD( nstatavg*jmax*idummy , isize_txc_field ) > 0 ) THEN
        idummy = nstatavg*jmax*idummy / isize_txc_field + 1
      ELSE
        idummy = nstatavg*jmax*idummy / isize_txc_field
      ENDIF
      inb_txc = MAX(inb_txc,idummy)
    ENDIF

  ENDIF

#ifdef USE_PSFFT
  IF ( imode_rhs == EQNS_RHS_NONBLOCKING ) inb_txc = MAX(inb_txc,15)
#endif

  isize_wrk3d = MAX(imax,g_inf(1)%size)*MAX(jmax,g_inf(2)%size)*kmax
  isize_wrk3d = MAX(isize_wrk3d,isize_txc_field)
  IF (imode_part /= PART_TYPE_NONE) THEN
    isize_wrk3d = MAX(isize_wrk3d,(imax+1)*jmax*(kmax+1))
    isize_wrk3d = MAX(isize_wrk3d,(jmax*(kmax+1)*inb_part_interp*2))
    isize_wrk3d = MAX(isize_wrk3d,(jmax*(imax+1)*inb_part_interp*2))
  END IF
  IF ( use_tower ) THEN
    isize_wrk3d = MAX(isize_wrk3d,nitera_save*(g(2)%size+2))
  ENDIF

  RETURN
END SUBROUTINE DNS_READ_LOCAL
