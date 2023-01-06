#include "dns_const.h"

!########################################################################
!#
!# Scalar equation, nonlinear term in divergence form and the
!# diffusion term explicit. 3 2nd order + 3 1st order derivatives.
!#
!########################################################################
subroutine RHS_SCAL_GLOBAL_INCOMPRESSIBLE_3(is)
    use TLAB_CONSTANTS, only: wp, wi
    use TLAB_VARS, only: imax, jmax, kmax
    use TLAB_VARS, only: g
    use TLAB_VARS, only: idiffusion, visc, schmidt
    use TLAB_ARRAYS, only: s, wrk2d, wrk3d
    use TLAB_POINTERS, only: u, v, w, tmp1, tmp2, tmp3, tmp4, tmp5, tmp6
    use DNS_ARRAYS, only: hs
    use OPR_PARTIAL

    implicit none

    integer(wi), intent(in) :: is

! -----------------------------------------------------------------------
    integer(wi) ij, i, k, bcs(2, 2)
    real(wp) diff

! #######################################################################
    bcs = 0

    if (idiffusion == EQNS_NONE) then; diff = 0.0_wp
    else; diff = visc/schmidt(is); end if

! #######################################################################
! Diffusion and convection terms in scalar equations
! #######################################################################
    call OPR_PARTIAL_Z(OPR_P2, imax, jmax, kmax, bcs, g(3), s(:, is), tmp6, tmp3, wrk2d, wrk3d)
    call OPR_PARTIAL_Y(OPR_P2, imax, jmax, kmax, bcs, g(2), s(:, is), tmp5, tmp2, wrk2d, wrk3d)
    call OPR_PARTIAL_X(OPR_P2, imax, jmax, kmax, bcs, g(1), s(:, is), tmp4, tmp1, wrk2d, wrk3d)
    hs(:, is) = hs(:, is) + diff*(tmp6 + tmp5 + tmp4)

    tmp6 = s(:, is)*w
    tmp5 = s(:, is)*v
    tmp4 = s(:, is)*u
    call OPR_PARTIAL_Z(OPR_P1, imax, jmax, kmax, bcs, g(3), tmp6, tmp3, wrk3d, wrk2d, wrk3d)
! which BCs should I use here ?
    call OPR_PARTIAL_Y(OPR_P1, imax, jmax, kmax, bcs, g(2), tmp5, tmp2, wrk3d, wrk2d, wrk3d)
    call OPR_PARTIAL_X(OPR_P1, imax, jmax, kmax, bcs, g(1), tmp4, tmp1, wrk3d, wrk2d, wrk3d)
    hs(:, is) = hs(:, is) - (tmp3 + tmp2 + tmp1)

! -----------------------------------------------------------------------
! Dilatation term
! -----------------------------------------------------------------------
    call OPR_PARTIAL_Z(OPR_P1, imax, jmax, kmax, bcs, g(3), w, tmp3, wrk3d, wrk2d, wrk3d)
    call OPR_PARTIAL_Y(OPR_P1, imax, jmax, kmax, bcs, g(2), v, tmp2, wrk3d, wrk2d, wrk3d)
    call OPR_PARTIAL_X(OPR_P1, imax, jmax, kmax, bcs, g(1), u, tmp1, wrk3d, wrk2d, wrk3d)
!     hs = hs + s*( tmp3 + tmp2 + tmp1 )
    do k = 1, kmax
        do i = 1, imax
            ij = i + imax*jmax*(k - 1) ! bottom
            hs(ij, is) = hs(ij, is) + s(ij, is)*(tmp3(ij) + tmp2(ij) + tmp1(ij))
            ij = i + imax*(jmax - 1) + imax*jmax*(k - 1) ! top
            hs(ij, is) = hs(ij, is) + s(ij, is)*(tmp3(ij) + tmp2(ij) + tmp1(ij))
        end do
    end do

    return
end subroutine RHS_SCAL_GLOBAL_INCOMPRESSIBLE_3
