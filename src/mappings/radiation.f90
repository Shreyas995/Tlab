#include "dns_const.h"
#include "dns_error.h"

module Radiation
    use TLAB_CONSTANTS, only: wp, wi, pi_wp, BCS_MAX, BCS_MIN, efile, MAX_PROF
    use TLAB_TYPES, only: term_dt, grid_dt
    use TLAB_VARS, only: imode_eqns, inb_scal_array
    use TLAB_ARRAYS, only: wrk2d, wrk3d
    use TLAB_PROCS, only: TLAB_WRITE_ASCII, TLAB_STOP
    use Thermodynamics, only: imixture
    use OPR_ODES
    use Integration
    implicit none
    private

    integer, parameter :: TYPE_NONE = 0
    integer, parameter :: TYPE_IR_GRAY_LIQUID = 1
    integer, parameter :: TYPE_IR_GRAY = 2
    integer, parameter :: TYPE_IR_TWOBANDS = 3
    integer, parameter :: TYPE_BULK1DLOCAL = 10         ! backwards compatibility, to be removed

    real(wp), parameter :: sigma = 5.67037442e-8_wp     ! Stefan-Boltzmann constant, W /m^2 /K^4
    real(wp) :: mu                                      ! mean direction parameter
    real(wp) :: epsilon                                 ! surface emissivity at ymin
    real(wp), allocatable, target :: bcs(:)

    public :: Radiation_Initialize
    public :: Radiation_Infrared

contains
!########################################################################
!########################################################################
    subroutine Radiation_Initialize(inifile)
        use TLAB_VARS, only: infrared, imax, kmax
        character(len=*), intent(in) :: inifile

        ! -------------------------------------------------------------------
        character(len=32) bakfile, block
        character(len=512) sRes
        integer(wi) idummy

        !########################################################################
        bakfile = trim(adjustl(inifile))//'.bak'
        block = 'Infrared'

        call TLAB_WRITE_ASCII(bakfile, '#')
        call TLAB_WRITE_ASCII(bakfile, '#['//trim(adjustl(block))//']')
        call TLAB_WRITE_ASCII(bakfile, '#Type=<value>')
        call TLAB_WRITE_ASCII(bakfile, '#Scalar=<value>')
        call TLAB_WRITE_ASCII(bakfile, '#Parameters=<value>')

        call SCANINICHAR(bakfile, inifile, block, 'Type', 'None', sRes)
        if (trim(adjustl(sRes)) == 'none') &
            call SCANINICHAR(bakfile, inifile, 'Main', 'TermRadiation', 'None', sRes)               ! backwards compatibility, to be removed
        if (trim(adjustl(sRes)) == 'none') then; infrared%type = TYPE_NONE
        else if (trim(adjustl(sRes)) == 'grayliquid') then; infrared%type = TYPE_IR_GRAY_LIQUID
        else if (trim(adjustl(sRes)) == 'gray') then; infrared%type = TYPE_IR_GRAY
        else if (trim(adjustl(sRes)) == 'twobands') then; infrared%type = TYPE_IR_TWOBANDS
        else if (trim(adjustl(sRes)) == 'bulk1dlocal') then; infrared%type = TYPE_BULK1DLOCAL    ! backwards compatibility, to be removed
        else
            call TLAB_WRITE_ASCII(efile, __FILE__//'. Error in Radiation.Type.')
            call TLAB_STOP(DNS_ERROR_OPTION)
        end if

        infrared%active = .false.
        if (infrared%type /= TYPE_NONE) then
            call SCANINIINT(bakfile, inifile, block, 'Scalar', '1', idummy)
            infrared%active(idummy) = .true.

            infrared%parameters(:) = 0.0_wp
            call SCANINICHAR(bakfile, inifile, block, 'Parameters', '1.0', sRes)
            idummy = MAX_PROF
            call LIST_REAL(sRes, idummy, infrared%parameters)

        end if

        ! -------------------------------------------------------------------
        ! By default, radiation is caused by last scalar
        infrared%scalar = inb_scal_array

        if (imixture == MIXT_TYPE_AIRWATER .or. imixture == MIXT_TYPE_AIRWATER_LINEAR) then
            if (infrared%type /= EQNS_NONE) then
                infrared%active(inb_scal_array) = .true. ! liquid
                infrared%active(inb_scal_array + 1) = .true. ! buoyancy
            end if

        end if

        ! backwards compatibility
        if (infrared%type == TYPE_BULK1DLOCAL) then
            infrared%parameters(1) = infrared%parameters(1)*infrared%parameters(2)
            infrared%parameters(3) = infrared%parameters(3)*infrared%parameters(2)
            infrared%parameters(2) = 1.0_wp/infrared%parameters(2)
        end if

        ! -------------------------------------------------------------------
        ! in case nondimensional we need to adjust sigma; tbd

        ! sigma_o_pi = sigma/pi_wp
        ! sigma_o_pi = 0.0_wp       ! testing

        mu = 0.5_wp*(1.0_wp/sqrt(3.0_wp) + 1.0_wp/sqrt(2.0_wp))     ! mean direction, in (1/sqrt{3}, 1/sqrt{2})
        ! mu = 1.0_wp/sqrt(2.0_wp)
        ! mu = 0.5_wp     ! testing

        allocate (bcs(imax*kmax))

        ! !########################################################################
        ! bakfile = trim(adjustl(inifile))//'.bak'
        ! block = 'Visible'

        return
    end subroutine Radiation_Initialize

!########################################################################
!########################################################################
    subroutine Radiation_Infrared(infrared, nx, ny, nz, g, s, source, b, tmp1, tmp2, flux)
        use THERMO_ANELASTIC
        type(term_dt), intent(in) :: infrared
        integer(wi), intent(in) :: nx, ny, nz
        type(grid_dt), intent(in) :: g
        real(wp), intent(in) :: s(nx*ny*nz, inb_scal_array)
        real(wp), intent(out) :: source(nx*ny*nz)   ! also used for bulk absorption coefficient
        real(wp), intent(inout) :: b(nx*ny*nz)      ! emission function
        real(wp), intent(inout) :: tmp1(nx*ny*nz), tmp2(nx*ny*nz)
        real(wp), intent(out), optional :: flux(nx*ny*nz)

        ! -----------------------------------------------------------------------
        integer iband
        integer, parameter :: nbands = 2        ! number of spectral bands
        real(wp) kappal, kappav(nbands)

        !########################################################################
        select case (infrared%type)
        case (TYPE_IR_GRAY_LIQUID, TYPE_BULK1DLOCAL)
            ! infrared%parameters(1) downward flux at domain top
            kappal = infrared%parameters(2)     ! mass absorptivity coefficient of liquid
            ! infrared%parameters(3) upward flux at domain bottom

            source = kappal*s(:, infrared%scalar(1))        ! bulk absorption coefficient in array source to save memory
            if (imode_eqns == DNS_EQNS_ANELASTIC) then
                call THERMO_ANELASTIC_WEIGHT_INPLACE(nx, ny, nz, rbackground, source)
            end if

            if (present(flux)) then
                call IR_RTE_Y_Liquid(infrared, nx, ny, nz, g, source, flux)
            else
                call IR_RTE_Y_Liquid(infrared, nx, ny, nz, g, source)
            end if

        ! -----------------------------------------------------------------------
        case (TYPE_IR_GRAY)
            ! infrared%parameters(1) downward flux at domain top
            kappal = infrared%parameters(2)     ! mass absorptivity coefficient of liquid
            kappav(1) = infrared%parameters(3)  ! mass absorptivity coefficient of vapor
            epsilon = infrared%parameters(4)    ! surface emissivity at ymin

            ! bulk absorption coefficient; in array source to save memory
            source = kappal*s(:, infrared%scalar(1)) + kappav(1)*(s(:, 2) - s(:, infrared%scalar(1)))
            if (imode_eqns == DNS_EQNS_ANELASTIC) then
                call THERMO_ANELASTIC_WEIGHT_INPLACE(nx, ny, nz, rbackground, source)   ! multiply by density
                call THERMO_ANELASTIC_TEMPERATURE(nx, ny, nz, s, wrk3d)                 ! calculate temperature for emission function
            else
                ! tbd
            end if
            b = sigma*wrk3d**4.0_wp             ! emission function

            if (present(flux)) then             ! solve radiative transfer equation along y
                call IR_RTE_Y_Global(infrared, nx, ny, nz, g, source, b, tmp1, tmp2, flux)
                ! call IR_RTE_Y_Local(infrared, nx, ny, nz, g, source, b, tmp1, tmp2, flux)
                ! call IR_RTE_Y_Incremental(infrared, nx, ny, nz, g, source, b, tmp1, flux)
            else
                call IR_RTE_Y_Global(infrared, nx, ny, nz, g, source, b, tmp1, tmp2)
                ! call IR_RTE_Y_Local(infrared, nx, ny, nz, g, source, b, tmp1, tmp2)
                ! call IR_RTE_Y_Incremental(infrared, nx, ny, nz, g, source, b, tmp1, flux)
            end if

        ! -----------------------------------------------------------------------
        case (TYPE_IR_TWOBANDS)
            ! infrared%parameters(1) downward flux at domain top
            kappal = infrared%parameters(2)     ! mass absorptivity coefficient of liquid
            kappav(1) = infrared%parameters(3)  ! mass absorptivity coefficient of vapor, band 1
            kappav(2) = infrared%parameters(4)  ! mass absorptivity coefficient of vapor, band 2
            epsilon = infrared%parameters(5)    ! surface emissivity at ymin

            ! liquid
            source = kappal*s(:, infrared%scalar(1))
            if (imode_eqns == DNS_EQNS_ANELASTIC) then
                call THERMO_ANELASTIC_WEIGHT_INPLACE(nx, ny, nz, rbackground, source)   ! multiply by density
                call THERMO_ANELASTIC_TEMPERATURE(nx, ny, nz, s, wrk3d)                 ! calculate temperature for emission function
            else
                ! tbd
            end if
            b = sigma*wrk3d**4.0_wp             ! emission function
            ! call rte routine

            ! vapor
            tmp1 = s(:, 2) - s(:, infrared%scalar(1))
            if (imode_eqns == DNS_EQNS_ANELASTIC) then
                call THERMO_ANELASTIC_WEIGHT_INPLACE(nx, ny, nz, rbackground, tmp1)     ! multiply by density
                call THERMO_ANELASTIC_TEMPERATURE(nx, ny, nz, s, tmp2)                  ! calculate temperature for emission function
            else
                ! tbd
            end if
            do iband = 1, nbands
                source = kappav(iband)*tmp1
                b = sigma*wrk3d**4.0_wp             ! emission function
                ! call rte routine
                ! accumulate
            end do

        end select

    end subroutine Radiation_Infrared

!########################################################################
!########################################################################
    ! Radiative transfer equation along y; only liquid
    subroutine IR_RTE_Y_Liquid(infrared, nx, ny, nz, g, a_source, flux)
        type(term_dt), intent(in) :: infrared
        integer(wi), intent(in) :: nx, ny, nz
        type(grid_dt), intent(in) :: g
        real(wp), intent(inout) :: a_source(nx*nz, ny)      ! input as bulk absorption coefficent, output as source
        real(wp), intent(out), optional :: flux(nx*nz, ny)

        target a_source, flux

! -----------------------------------------------------------------------
        integer(wi) j, nxy, nxz
        real(wp) fd, fu
        real(wp), pointer :: p_a(:, :) => null()
        real(wp), pointer :: p_tau(:, :) => null()
        real(wp), pointer :: p_source(:, :) => null()
        real(wp), pointer :: p_flux(:, :) => null()

! #######################################################################
        nxy = nx*ny     ! For transposition to make y direction the last one
        nxz = nx*nz

        if (nz == 1) then
            p_a => a_source
            p_source => a_source
            p_tau(1:nx*nz, 1:ny) => wrk3d(1:nx*ny*nz)
            if (present(flux)) p_flux => flux
        else
            p_a(1:nx*nz, 1:ny) => wrk3d(1:nx*ny*nz)
            p_source(1:nx*nz, 1:ny) => wrk3d(1:nx*ny*nz)
            if (present(flux)) then
                p_tau => flux
                p_flux(1:nx*nz, 1:ny) => wrk3d(1:nx*ny*nz)
            else
                p_tau => a_source
            end if

#ifdef USE_ESSL
            call DGETMO(a_source, nxy, nxy, nz, p_a, nz)
#else
            call DNS_TRANSPOSE(a_source, nxy, nz, nxy, p_a, nz)
#endif
        end if

! ###################################################################
        ! Calculate (negative) optical thickness; integrating from the top, to be checked
        p_tau(:, ny) = 0.0_wp   ! boundary condition
        call OPR_Integral1(nxz, g, p_a, p_tau, BCS_MAX)
        ! p_tau(:, 1) = 0.0_wp     ! boundary condition
        ! call OPR_Integral1(nxz, g, p_org, p_tau, BCS_MIN)

! Calculate exp(-tau(z, zmax)/\mu)
        do j = ny, 1, -1
            p_tau(:, j) = exp(p_tau(:, j))
        end do
        !  p_tau = dexp(p_tau)         seg-fault; need ulimit -u unlimited

! ###################################################################
! Calculate heating rate
        fd = infrared%parameters(1)
        fu = infrared%parameters(3)
        if (abs(infrared%parameters(3)) > 0.0_wp) then
            do j = ny, 1, -1
                p_source(:, j) = p_a(:, j)*(p_tau(:, j)*fd &                       ! downward flux
                                            + p_tau(:, 1)/p_tau(:, j)*fu)       ! upward flux
            end do
        else
            p_source = p_a*p_tau*fd
        end if

        if (nz > 1) then ! Put arrays back in the order in which they came in
#ifdef USE_ESSL
            call DGETMO(p_source, nz, nz, nxy, a_source, nxy)
#else
            call DNS_TRANSPOSE(p_source, nz, nxy, nz, a_source, nxy)
#endif
        end if

! ###################################################################
! Calculate radiative flux, if necessary
        if (present(flux)) then
            fd = -infrared%parameters(1)
            fu = infrared%parameters(3)
            if (abs(infrared%parameters(3)) > 0.0_wp) then
                do j = ny, 1, -1
                    p_flux(:, j) = fd*p_tau(:, j) &                       ! downward flux
                                   + fu*p_tau(:, 1)/p_tau(:, j)       ! upward flux
                end do
            else
                p_flux = p_tau*fd
            end if

            if (nz > 1) then ! Put arrays back in the order in which they came in
#ifdef USE_ESSL
                call DGETMO(p_flux, nz, nz, nxy, flux, nxy)
#else
                call DNS_TRANSPOSE(p_flux, nz, nxy, nz, flux, nxy)
#endif
            end if

        end if

! ###################################################################
        nullify (p_a, p_tau, p_source, p_flux)

        return
    end subroutine IR_RTE_Y_Liquid

!########################################################################
!########################################################################
    ! Radiative transfer equation along y
    ! Here we do not treat separately 2d and 3d cases for the trasposition because it was a bit messy...
    subroutine IR_RTE_Y_Incremental(infrared, nx, ny, nz, g, a_source, b, tmp1, flux)
        type(term_dt), intent(in) :: infrared
        integer(wi), intent(in) :: nx, ny, nz
        type(grid_dt), intent(in) :: g
        real(wp), intent(inout) :: a_source(nx*nz, ny)          ! input as bulk absorption coefficent, output as source
        real(wp), intent(inout) :: b(nx*nz, ny)                 ! input as emission function, output as upward flux, if flux is to be return
        real(wp), intent(inout) :: tmp1(nx*nz, ny)
        real(wp), intent(out), optional :: flux(nx*nz, ny)

        target a_source, b, tmp1

! -----------------------------------------------------------------------
        integer(wi) j, nxy, nxz
        real(wp) dummy
        real(wp), pointer :: p_a(:, :) => null()
        real(wp), pointer :: p_tau(:, :) => null()
        real(wp), pointer :: p_ab(:, :) => null()
        real(wp), pointer :: p_source(:, :) => null()
        real(wp), pointer :: p_flux(:, :) => null()
        real(wp), pointer :: p_flux_up(:) => null()
        real(wp), pointer :: p_wrk2d_1(:) => null()
        real(wp), pointer :: p_wrk2d_2(:) => null()

! #######################################################################
        nxy = nx*ny     ! For transposition to make y direction the last one
        nxz = nx*nz

        p_a(1:nx*nz, 1:ny) => wrk3d(1:nx*ny*nz)
        p_source(1:nx*nz, 1:ny) => wrk3d(1:nx*ny*nz)
        p_ab => a_source
        p_tau => b
        p_flux => tmp1
        p_flux_up(1:nx*nz) => bcs(1:nx*nz)
        p_wrk2d_1(1:nx*nz) => wrk2d(1:nx*nz, 1)
        p_wrk2d_2(1:nx*nz) => wrk2d(1:nx*nz, 2)

#ifdef USE_ESSL
        call DGETMO(a_source, nxy, nxy, nz, p_a, nz)
        call DGETMO(b, nxy, nxy, nz, p_ab, nz)
#else
        call DNS_TRANSPOSE(a_source, nxy, nz, nxy, p_a, nz)
        call DNS_TRANSPOSE(b, nxy, nz, nxy, p_ab, nz)
#endif

! ###################################################################
        ! absorption coefficient; divide by mean direction
        dummy = 1.0_wp/mu
        p_a = p_a*dummy

        ! emission function
        p_flux_up = p_ab(:, 1)            ! save for calculation of surface flux
        p_ab = p_ab*p_a                   ! absorption coefficient times emission function

        ! test
        ! p_ab = 0.0_wp   ! test
        ! p_ab = 1.0_wp   ! test
        ! p_flux_up = 0.0_wp
        ! p_flux_up = infrared%parameters(1)

        ! p_a = 0.01_wp    ! test
        ! p_a = 0.0_wp    ! test

        ! ###################################################################
        ! calculate f_j = exp(-tau(z_{j-1}, z_j)/\mu)
        p_tau(:, 1) = 0.0_wp                                    ! boundary condition
        ! call OPR_Integral1(nxz, g, p_a, p_tau, BCS_MIN)
        ! call Int_Trapezoidal_f(p_a, g%nodes, p_tau, BCS_MIN)
        call Int_Simpson_Biased_f(p_a, g%nodes, p_tau, BCS_MIN)
        do j = ny, 2, -1
            p_tau(:, j) = exp(p_tau(:, j - 1) - p_tau(:, j))
        end do
        p_tau(:, 1) = 1.0_wp        ! this value is not used

        ! ###################################################################
        ! downward flux; positive going down
        j = ny
        p_flux(:, j) = infrared%parameters(1)

        do j = ny - 1, 1, -1
            ! Integral contribution from emission function using a trapezoidal rule
            p_wrk2d_2 = p_ab(:, j + 1)
            p_wrk2d_1 = p_ab(:, j)/p_tau(:, j + 1)
            p_wrk2d_1 = 0.5_wp*(p_wrk2d_1 + p_wrk2d_2)*(g%nodes(j + 1) - g%nodes(j))

            p_flux(:, j) = p_tau(:, j + 1)*(p_flux(:, j + 1) + p_wrk2d_1)
        end do

        ! ###################################################################
        ! upward flux and source
        j = 1
        p_flux_up = epsilon*p_flux_up + (1.0_wp - epsilon)*p_flux(:, 1) ! bottom boundary condition
        p_source(:, j) = p_a(:, j)*(p_flux_up + p_flux(:, j)) - 2.0_wp*p_ab(:, j)

        if (present(flux)) then                                         ! Save fluxes
            p_flux(:, j) = p_flux_up - p_flux(:, j)                     ! total flux until transposition below
            flux(:, j) = p_flux_up                                      ! upward flux until transposition below

            do j = 2, ny
                ! Integral contribution from emission function using a trapezoidal rule
                p_wrk2d_1 = p_ab(:, j - 1)
                p_wrk2d_2 = p_ab(:, j)/p_tau(:, j)
                p_wrk2d_1 = 0.5_wp*(p_wrk2d_1 + p_wrk2d_2)*(g%nodes(j) - g%nodes(j - 1))

                p_flux_up = p_tau(:, j)*(p_flux_up + p_wrk2d_1)
                p_source(:, j) = p_a(:, j)*(p_flux_up + p_flux(:, j)) - 2.0_wp*p_ab(:, j)

                p_flux(:, j) = p_flux_up - p_flux(:, j)
                flux(:, j) = p_flux_up
            end do

            ! p_source = p_tau ! test

#ifdef USE_ESSL
            call DGETMO(flux, nz, nz, nxy, b, nxy)
            call DGETMO(p_flux, nz, nz, nxy, flux, nxy)
#else
            call DNS_TRANSPOSE(flux, nz, nxy, nz, b, nxy)
            call DNS_TRANSPOSE(p_flux, nz, nxy, nz, flux, nxy)
#endif
        else                                                            ! Do not save fluxes
            do j = 2, ny
                ! Integral contribution from emission function using a trapezoidal rule
                p_wrk2d_1 = p_ab(:, j - 1)
                p_wrk2d_2 = p_ab(:, j)/p_tau(:, j)
                p_wrk2d_1 = 0.5_wp*(p_wrk2d_1 + p_wrk2d_2)*(g%nodes(j) - g%nodes(j - 1))

                p_flux_up = p_tau(:, j)*(p_flux_up + p_wrk2d_1)
                p_source(:, j) = p_a(:, j)*(p_flux_up + p_flux(:, j)) - 2.0_wp*p_ab(:, j)
            end do

        end if

#ifdef USE_ESSL
        call DGETMO(p_source, nz, nz, nxy, a_source, nxy)
#else
        call DNS_TRANSPOSE(p_source, nz, nxy, nz, a_source, nxy)
#endif

! ###################################################################
        nullify (p_a, p_tau, p_ab, p_source, p_flux, p_flux_up, p_wrk2d_1, p_wrk2d_2)

        return
    end subroutine IR_RTE_Y_Incremental

!########################################################################
!########################################################################
    ! Radiative transfer equation along y
    ! Here we do not treat separately 2d and 3d cases for the trasposition because it was a bit messy...
    subroutine IR_RTE_Y_Local(infrared, nx, ny, nz, g, a_source, b, tmp1, tmp2, flux)
        type(term_dt), intent(in) :: infrared
        integer(wi), intent(in) :: nx, ny, nz
        type(grid_dt), intent(in) :: g
        real(wp), intent(inout) :: a_source(nx*nz, ny)          ! input as bulk absorption coefficent, output as source
        real(wp), intent(inout) :: b(nx*nz, ny)                 ! input as emission function, output as upward flux, if flux is to be return
        real(wp), intent(inout) :: tmp1(nx*nz, ny)
        real(wp), intent(inout) :: tmp2(nx*nz, ny)
        real(wp), intent(out), optional :: flux(nx*nz, ny)

        target a_source, b, tmp1

! -----------------------------------------------------------------------
        integer(wi) j, k, nxy, nxz
        real(wp) dummy
        real(wp), pointer :: p_a(:, :) => null()
        real(wp), pointer :: p_tau(:, :) => null()
        real(wp), pointer :: p_ab(:, :) => null()
        real(wp), pointer :: p_source(:, :) => null()
        real(wp), pointer :: p_flux(:, :) => null()
        real(wp), pointer :: p_bcs(:) => null()
        real(wp), pointer :: p_flux_1(:) => null()
        real(wp), pointer :: p_flux_2(:) => null()

! #######################################################################
        nxy = nx*ny     ! For transposition to make y direction the last one
        nxz = nx*nz

        p_a(1:nx*nz, 1:ny) => wrk3d(1:nx*ny*nz)
        p_source(1:nx*nz, 1:ny) => wrk3d(1:nx*ny*nz)
        p_ab => a_source
        p_tau => b
        p_flux => tmp1
        p_bcs(1:nx*nz) => bcs(1:nx*nz)
        p_flux_1(1:nx*nz) => wrk2d(1:nx*nz, 1)
        p_flux_2(1:nx*nz) => wrk2d(1:nx*nz, 2)

#ifdef USE_ESSL
        call DGETMO(a_source, nxy, nxy, nz, p_a, nz)
        call DGETMO(b, nxy, nxy, nz, p_ab, nz)
#else
        call DNS_TRANSPOSE(a_source, nxy, nz, nxy, p_a, nz)
        call DNS_TRANSPOSE(b, nxy, nz, nxy, p_ab, nz)
#endif

! ###################################################################
        ! absorption coefficient; divide by mean direction
        dummy = 1.0_wp/mu
        p_a = p_a*dummy

        ! emission function
        p_bcs = p_ab(:, 1)                ! save for calculation of surface flux
        p_ab = p_ab*p_a                   ! absorption coefficient times emission function

        ! test
        ! p_ab = 0.0_wp   ! test
        ! p_ab = 1.0_wp   ! test
        ! p_bcs = 0.0_wp
        ! p_bcs = infrared%parameters(1)

        ! p_a = 0.01_wp    ! test
        ! p_a = 0.0_wp    ! test

        ! ###################################################################
        ! calculate exp(-tau(zi, zj)/\mu)
        p_tau(:, 1) = 0.0_wp                                    ! boundary condition
        ! call OPR_Integral1(nxz, g, p_a, p_tau, BCS_MIN)
        ! call Int_Trapezoidal_f(p_a, g%nodes, p_tau, BCS_MIN)
        call Int_Simpson_Biased_f(p_a, g%nodes, p_tau, BCS_MIN)
        do j = ny, 2, -1
            p_tau(:, j) = exp(p_tau(:, j - 1) - p_tau(:, j))
        end do
        p_tau(:, 1) = 1.0_wp        ! this value is not used

        ! ###################################################################
        ! downward flux; positive going down
        j = ny
        p_flux_1 = infrared%parameters(1)
        p_flux(:, j) = p_flux_1

        do j = ny - 1, 1, -1
            p_flux_1 = p_flux_1*p_tau(:, j + 1)

            p_flux_2 = 1.0_wp       ! used as auxiliary array in the next loop
            tmp2(:, j) = p_ab(:, j)
            do k = j + 1, ny
                p_flux_2 = p_flux_2*p_tau(:, k)
                tmp2(:, k) = p_ab(:, k)*p_flux_2
            end do
            call Int_Simpson_v(tmp2(:, j:ny), g%nodes(j:ny), p_flux(:, j))
            ! call Int_Trapezoidal_v(tmp2(:, j:ny), g%nodes(j:ny), p_flux(:, j))
            p_flux(:, j) = p_flux(:, j) + p_flux_1
        end do

        ! ###################################################################
        ! bottom boundary condition; calculate upward flux at the bottom
        p_bcs = epsilon*p_bcs + (1.0_wp - epsilon)*p_flux(:, 1)

        ! ###################################################################
        ! upward flux and net terms
        j = 1
        p_flux_1 = p_bcs
        p_source(:, j) = p_a(:, j)*(p_flux_1 + p_flux(:, j)) - 2.0_wp*p_ab(:, j)

        if (present(flux)) then                                     ! I need additional space to store fluxes
            p_flux(:, j) = p_flux_1 - p_flux(:, j)                  ! total flux until transposition below
            flux(:, j) = p_flux_1                                   ! upward flux until transposition below

            do j = 2, ny
                p_flux_1 = p_flux_1*p_tau(:, j)

                p_flux_2 = 1.0_wp       ! used as auxiliary array in the next loop
                tmp2(:, j) = p_ab(:, j)
                do k = j - 1, 1, -1
                    p_flux_2 = p_flux_2*p_tau(:, k + 1)
                    tmp2(:, k) = p_ab(:, k)*p_flux_2
                end do
                call Int_Simpson_v(tmp2(:, 1:j), g%nodes(1:j), p_flux_2)
                ! call Int_Trapezoidal_v(tmp2(:, 1:j), g%nodes(1:j), p_flux_2)
                p_source(:, j) = p_a(:, j)*(p_flux_2 + p_flux_1 + p_flux(:, j)) - 2.0_wp*p_ab(:, j)

                p_flux(:, j) = p_flux_2 + p_flux_1 - p_flux(:, j)   ! total flux
                flux(:, j) = p_flux_2 + p_flux_1                    ! upward flux
            end do

#ifdef USE_ESSL
            call DGETMO(flux, nz, nz, nxy, b, nxy)
            call DGETMO(p_flux, nz, nz, nxy, flux, nxy)
#else
            call DNS_TRANSPOSE(flux, nz, nxy, nz, b, nxy)
            call DNS_TRANSPOSE(p_flux, nz, nxy, nz, flux, nxy)
#endif
        else                ! we only need the source term
            do j = 2, ny
                p_flux_1 = p_flux_1*p_tau(:, j)

                p_flux_2 = 1.0_wp       ! used as auxiliary array in the next loop
                tmp2(:, j) = p_ab(:, j)
                do k = j - 1, 1, -1
                    p_flux_2 = p_flux_2*p_tau(:, k + 1)
                    tmp2(:, k) = p_ab(:, k)*p_flux_2
                end do
                call Int_Simpson_v(tmp2(:, 1:j), g%nodes(1:j), p_flux_2)
                ! call Int_Trapezoidal_v(tmp2(:, 1:j), g%nodes(1:j), p_flux_2)
                p_source(:, j) = p_a(:, j)*(p_flux_2 + p_flux_1 + p_flux(:, j)) - 2.0_wp*p_ab(:, j)

            end do

        end if

#ifdef USE_ESSL
        call DGETMO(p_source, nz, nz, nxy, a_source, nxy)
#else
        call DNS_TRANSPOSE(p_source, nz, nxy, nz, a_source, nxy)
#endif

! ###################################################################
        nullify (p_a, p_tau, p_ab, p_source, p_flux, p_bcs)

        return
    end subroutine IR_RTE_Y_Local

!########################################################################
!########################################################################
    subroutine IR_RTE_Y_Global(infrared, nx, ny, nz, g, a_source, b, tmp1, tmp2, flux)
        type(term_dt), intent(in) :: infrared
        integer(wi), intent(in) :: nx, ny, nz
        type(grid_dt), intent(in) :: g
        real(wp), intent(inout) :: a_source(nx*nz, ny)          ! input as bulk absorption coefficent, output as source
        real(wp), intent(inout) :: b(nx*nz, ny)                 ! input as emission function, output as upward flux, if flux is to be return
        real(wp), intent(inout) :: tmp1(nx*nz, ny)
        real(wp), intent(inout) :: tmp2(nx*nz, ny)
        real(wp), intent(out), optional :: flux(nx*nz, ny)

        target a_source, b, tmp1

! -----------------------------------------------------------------------
        integer(wi) j, nxy, nxz
        real(wp) fd, dummy
        real(wp), pointer :: p_a(:, :) => null()
        real(wp), pointer :: p_tau(:, :) => null()
        real(wp), pointer :: p_ab(:, :) => null()
        real(wp), pointer :: p_source(:, :) => null()
        real(wp), pointer :: p_flux(:, :) => null()
        real(wp), pointer :: p_bcs(:) => null()

! #######################################################################
        nxy = nx*ny     ! For transposition to make y direction the last one
        nxz = nx*nz

        p_a(1:nx*nz, 1:ny) => wrk3d(1:nx*ny*nz)
        p_source(1:nx*nz, 1:ny) => wrk3d(1:nx*ny*nz)
        p_ab => a_source
        p_tau => b
        p_flux => tmp1
        p_bcs(1:nx*nz) => bcs(1:nx*nz)

#ifdef USE_ESSL
        call DGETMO(a_source, nxy, nxy, nz, p_a, nz)
        call DGETMO(b, nxy, nxy, nz, p_ab, nz)
#else
        call DNS_TRANSPOSE(a_source, nxy, nz, nxy, p_a, nz)
        call DNS_TRANSPOSE(b, nxy, nz, nxy, p_ab, nz)
#endif

! ###################################################################
        ! absorption coefficient; divide by mean direction
        dummy = 1.0_wp/mu
        p_a = p_a*dummy

        ! emission function
        p_bcs = p_ab(:, 1)                ! save for calculation of surface flux
        p_ab = p_ab*p_a                   ! absorption coefficient times emission function

        ! test
        ! p_ab = 0.0_wp   ! test
        ! p_ab = 1.0_wp   ! test
        ! p_bcs = 0.0_wp
        ! p_bcs = infrared%parameters(1)

        ! p_a = 0.01_wp    ! test
        ! p_a = 0.0_wp    ! test

        ! ###################################################################
        ! downward flux; positive going down

        ! calculate f_j = exp(-tau(z_j, zmax)/\mu)
        p_tau(:, ny) = 0.0_wp                                   ! boundary condition
        ! call OPR_Integral1(nxz, g, p_a, p_tau, BCS_MAX)            ! recall this gives the negative of the integral
        ! call Int_Trapezoidal_f(p_a, g%nodes, p_tau, BCS_MAX)
        call Int_Simpson_Biased_f(p_a, g%nodes, p_tau, BCS_MAX)
        do j = ny, 1, -1
            p_tau(:, j) = exp(-p_tau(:, j))
        end do
        !  p_tau = dexp(p_tau)         seg-fault; need ulimit -u unlimited

        p_flux = p_ab/p_tau
        ! call Int_Trapezoidal_Increments_InPlace(p_flux, g%nodes, BCS_MAX)                   ! Calculate I_j = int_{x_{j}}^{x_{j+1}}
        call Int_Simpson_Biased_Increments_InPlace(p_flux, g%nodes, wrk2d(:, 1), BCS_MAX)   ! Calculate I_j = int_{x_{j}}^{x_{j+1}}
        p_flux(:, ny) = 0.0_wp
        do j = ny - 1, 1, -1
            p_flux(:, j) = p_flux(:, j + 1) + p_flux(:, j)
        end do
        fd = infrared%parameters(1)
        p_flux = p_tau*(fd + p_flux)

        ! ###################################################################
        ! upward flux
        p_bcs = epsilon*p_bcs + (1.0_wp - epsilon)*p_flux(:, 1) ! bottom boundary condition
        ! p_bcs = 0.0_wp  ! test

        ! calculate exp(-tau(zmin, z)/\mu)
        p_tau(:, 1) = 0.0_wp                                    ! boundary condition
        ! call OPR_Integral1(nxz, g, p_a, p_tau, BCS_MIN)
        ! call Int_Trapezoidal_f(p_a, g%nodes, p_tau, BCS_MIN)
        call Int_Simpson_Biased_f(p_a, g%nodes, p_tau, BCS_MIN)
        do j = 1, ny
            p_tau(:, j) = exp(-p_tau(:, j))
        end do

        tmp2 = p_ab/p_tau
        ! call Int_Trapezoidal_Increments_InPlace(tmp2, g%nodes, BCS_MIN)                     ! Calculate I_j = int_{x_{j-1}}^{x_{j}}
        call Int_Simpson_Biased_Increments_InPlace(tmp2, g%nodes, wrk2d(:, 1), BCS_MIN)     ! Calculate I_j = int_{x_{j-1}}^{x_{j}}
        tmp2(:, 1) = 0.0_wp
        do j = 2, ny
            tmp2(:, j) = tmp2(:, j - 1) + tmp2(:, j)
        end do
        !
        do j = ny, 1, -1
            tmp2(:, j) = p_tau(:, j)*(p_bcs(:) + tmp2(:, j))    ! upward flux
            p_source(:, j) = p_a(:, j)*(tmp2(:, j) + p_flux(:, j)) - 2.0_wp*p_ab(:, j)
            p_flux(:, j) = tmp2(:, j) - p_flux(:, j)            ! total flux
        end do

        if (present(flux)) then
#ifdef USE_ESSL
            call DGETMO(p_flux, nz, nz, nxy, flux, nxy)
            call DGETMO(tmp2, nz, nz, nxy, b, nxy)
#else
            call DNS_TRANSPOSE(p_flux, nz, nxy, nz, flux, nxy)
            call DNS_TRANSPOSE(tmp2, nz, nxy, nz, b, nxy)
#endif
        end if

#ifdef USE_ESSL
        call DGETMO(p_source, nz, nz, nxy, a_source, nxy)
#else
        call DNS_TRANSPOSE(p_source, nz, nxy, nz, a_source, nxy)
#endif

! ###################################################################
        nullify (p_a, p_tau, p_ab, p_source, p_flux, p_bcs)

        return
    end subroutine IR_RTE_Y_Global

end module
