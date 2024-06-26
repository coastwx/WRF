
!WRF:MEDIATION_LAYER:FIRE_MODEL
! Routines dealing with the atmosphere

module module_fr_fire_atm

use module_model_constants, only: cp,xlv
use module_fr_fire_util
use module_state_description, only: num_tracer 
use module_state_description, only: p_fire_smoke

contains

! DME subroutine for passive tracers
subroutine add_fire_tracer_emissions(    &
       tracer_opt,dt,dx,dy,              &
       ifms,ifme,jfms,jfme,              &
       ifts,ifte,jtfs,jfte,              &
       ids,ide,kds,kde,jds,jde,          &
       ims,ime,kms,kme,jms,jme,          &
       its,ite,kts,kte,jts,jte,          &
       rho,dz8w,                         &
       burnt_area_dt,fgip,               &
       tracer,fire_tracer_smoke,         &
       fire_smk_scheme,fire_smk_peak,fire_smk_ext,fire_tg_ub,zs,z_at_w  & !for Truncated Gaussian dist. 
)

implicit none
! arguments
integer,intent(in)::tracer_opt
real,intent(in)::fire_tracer_smoke
real,intent(in)::dt,dx,dy
integer,intent(in)::ifms,ifme,jfms,jfme,ifts,ifte,jtfs,jfte,ids,ide,kds,kde,jds,jde,ims,ime,kms,kme,jms,jme,its,ite,kts,kte,jts,jte
real,intent(in)::rho(ims:ime,kms:kme,jms:jme),dz8w(ims:ime,kms:kme,jms:jme)
real,intent(in),dimension(ifms:ifme,jfms:jfme)::burnt_area_dt,fgip
real,intent(inout)::tracer(ims:ime,kms:kme,jms:jme,num_tracer)

integer, intent(in) :: fire_smk_scheme !switch for smoke release
real, intent(in) :: fire_smk_peak !peak smoke release height for TG
real, intent(in) :: fire_smk_ext  !smoke extinction depth for TG
real, intent(in) :: fire_tg_ub    !upper bound of TG
real, intent(in), dimension( ims:ime,kms:kme,jms:jme ) :: z_at_w ! m abv sealvl
real, intent(in), dimension( ims:ime,jms:jme ) :: zs  ! topography (m abv sealvl)

! local
integer::isz1,jsz1,isz2,jsz2,ir,jr
integer::i,j,ibase,jbase,i_f,ioff,j_f,joff
real::avgw,emis,conv
integer :: i_st,i_en,j_st,j_en

!local for TG
integer :: k,k_st,k_en
real, dimension(its:ite,kts:kte,jts:jte) :: prop_smk

isz1 = ite-its+1
jsz1 = jte-jts+1
isz2 = ifte-ifts+1
jsz2 = jfte-jtfs+1
ir=isz2/isz1
jr=jsz2/jsz1
avgw = 1.0/(ir*jr)

! --- set loop indicies
i_st = MAX(its,ids+1)
i_en = MIN(ite,ide-2)
j_st = MAX(jts,jds+1)
j_en = MIN(jte,jde-2)

! --- check if TG used: init prop_smk
if (fire_smk_scheme .eq. 1) then
   k_st = kts
   k_en = MIN(kte,kde-1)
   call tg_dist(ims,ime, kms,kme, jms,jme, &
                i_st,i_en, j_st,j_en, k_st,k_en, dz8w, &
                fire_smk_peak,fire_tg_ub,fire_smk_ext,z_at_w,zs, &
                prop_smk)
end if

do j=j_st,j_en
    jbase=jtfs+jr*(j-jts)
    do i=i_st,i_st
       ibase=ifts+ir*(i-its)
       do joff=0,jr-1
           j_f=joff+jbase
           do ioff=0,ir-1
               i_f=ioff+ibase
               if (num_tracer > 0)then
                  if (fire_smk_scheme .eq. 0)then
                     emis=avgw*fire_tracer_smoke*burnt_area_dt(i_f,j_f)*fgip(i_f,j_f)*1000/(rho(i,kts,j)*dz8w(i,kts,j)) ! g_smoke/kg_air
                     tracer(i,kts,j,p_fire_smoke)=tracer(i,kts,j,p_fire_smoke)+emis
                  
                  else if (fire_smk_scheme .eq. 1)then
                     do k = k_st,k_en
                        emis=prop_smk(i,k,j)*avgw*fire_tracer_smoke*burnt_area_dt(i_f,j_f)*fgip(i_f,j_f)*1000/(rho(i,k,j)*dz8w(i,k,j)) ! g_smoke/kg_air
                        tracer(i,k,j,p_fire_smoke)=tracer(i,k,j,p_fire_smoke)+emis
                     end do
                  else
                     call wrf_error_fatal('Invalid fire smoke release option: check fire_smk_scheme namelist option')
                  end if
               end if
           enddo
       enddo
    enddo
enddo

end subroutine add_fire_tracer_emissions

!
!***
!

SUBROUTINE fire_tendency( &
    ids,ide, kds,kde, jds,jde,   & ! dimensions
    ims,ime, kms,kme, jms,jme,   &
    its,ite, kts,kte, jts,jte,   &
    grnhfx,grnqfx,canhfx,canqfx, & ! heat fluxes summed up to  atm grid
    alfg,alfc,z1can,             & ! coeffients, properties, geometry
    fire_sfc_flx,fire_heat_peak,fire_tg_ub,  & !options for heat release
    zs,z_at_w,dz8w,mu,c1h,c2h,rho, &
    rthfrten,rqvfrten)             ! theta and Qv tendencies

! This routine is atmospheric physics
! it does NOT go into module_fr_fire_phys because it is not related to fire physical processes

! --- this routine takes fire generated heat and moisture fluxes and
!     calculates their influence on the theta and water vapor
! --- note that these tendencies are valid at the Arakawa-A location

   IMPLICIT NONE

! --- incoming variables

   INTEGER , INTENT(in) :: ids,ide, kds,kde, jds,jde, &
                           ims,ime, kms,kme, jms,jme, &
                           its,ite, kts,kte, jts,jte

   REAL, INTENT(in), DIMENSION( ims:ime,jms:jme ) :: grnhfx,grnqfx  ! W/m^2
   REAL, INTENT(in), DIMENSION( ims:ime,jms:jme ) :: canhfx,canqfx  ! W/m^2
   REAL, INTENT(in), DIMENSION( ims:ime,jms:jme ) :: zs  ! topography (m abv sealvl)
   REAL, INTENT(in), DIMENSION( ims:ime,jms:jme ) :: mu  ! dry air mass (Pa)
   REAL, INTENT(in), DIMENSION( kms:kme         ) :: c1h, c2h ! Hybrid coordinate weights

   REAL, INTENT(in), DIMENSION( ims:ime,kms:kme,jms:jme ) :: z_at_w ! m abv sealvl
   REAL, INTENT(in), DIMENSION( ims:ime,kms:kme,jms:jme ) :: dz8w   ! dz across w-lvl
   REAL, INTENT(in), DIMENSION( ims:ime,kms:kme,jms:jme ) :: rho    ! density

   REAL, INTENT(in) :: alfg ! extinction depth surface fire heat (m)
   REAL, INTENT(in) :: alfc ! extinction depth crown  fire heat (m)
   REAL, INTENT(in) :: z1can    ! height of crown fire heat release (m)
   INTEGER, INTENT(in) :: fire_sfc_flx  !switch for the heat release scheme
   REAL, INTENT(in) :: fire_heat_peak   !peak heat release height for TG
   REAL, INTENT(in) :: fire_tg_ub       !upper bound for TG

! --- outgoing variables

   REAL, INTENT(out), DIMENSION( ims:ime,kms:kme,jms:jme ) ::   &
       rthfrten, & ! theta tendency from fire (in mass units)
       rqvfrten    ! Qv tendency from fire (in mass units)
! --- local variables

   INTEGER :: i,j,k
   INTEGER :: i_st,i_en, j_st,j_en, k_st,k_en

   REAL :: cp_i
   REAL :: rho_i
   REAL :: xlv_i
   REAL :: z_w
   REAL :: fact_g, fact_c
   REAL :: alfg_i, alfc_i

   REAL, DIMENSION( its:ite,kts:kte,jts:jte ) :: prop_heat !proportion of heat to be released fro TG dist.

   REAL, DIMENSION( its:ite,kts:kte,jts:jte ) :: hfx,qfx
   
!!   character(len=128)::msg

        do j=jts,jte
            do k=kts,min(kte+1,kde)
               do i=its,ite
                   rthfrten(i,k,j)=0.
                   rqvfrten(i,k,j)=0.
               enddo
            enddo
        enddo


! --- set some local constants
   

   cp_i = 1./cp     ! inverse of specific heat
   xlv_i = 1./xlv   ! inverse of latent heat
   alfg_i = 1./alfg
   alfc_i = 1./alfc

!!write(msg,'(8e11.3)')cp,cp_i,xlv,xlv_i,alfg,alfc,z1can
!!call message(msg)

   call print_2d_stats(its,ite,jts,jte,ims,ime,jms,jme,grnhfx,'fire_tendency:grnhfx')
   call print_2d_stats(its,ite,jts,jte,ims,ime,jms,jme,grnqfx,'fire_tendency:grnqfx')

! --- set loop indicies : note that

   i_st = MAX(its,ids+1)
   i_en = MIN(ite,ide-1)
   k_st = kts
   k_en = MIN(kte,kde-1)
   j_st = MAX(jts,jds+1)
   j_en = MIN(jte,jde-1)

! --- check if TG is used, and create proportion
   if (fire_sfc_flx .eq. 1) then !Truncated Gaussian scheme
      call tg_dist(ims,ime, kms,kme, jms,jme, &
                   i_st,i_en, j_st,j_en, k_st,k_en, dz8w, &
                   fire_heat_peak,fire_tg_ub,alfg,z_at_w,zs, &
                   prop_heat)
   end if

! --- distribute fluxes
   DO j = j_st,j_en
      DO k = k_st,k_en
         DO i = i_st,i_en
            if (fire_sfc_flx .eq. 0) then
                ! --- set z (in meters above ground)
                z_w = z_at_w(i,k,j) - zs(i,j) ! should be zero when k=k_st

                ! --- heat flux
                fact_g = cp_i * EXP( - alfg_i * z_w )
                IF ( z_w < z1can ) THEN
                   fact_c = cp_i
                ELSE
                   fact_c = cp_i * EXP( - alfc_i * (z_w - z1can) )
                END IF
                hfx(i,k,j) = fact_g * grnhfx(i,j) + fact_c * canhfx(i,j)

!!              write(msg,2)i,k,j,z_w,grnhfx(i,j),hfx(i,k,j)
!!2             format('hfx:',3i4,6e11.3)
!!              call message(msg)

                ! --- vapor flux

                fact_g = xlv_i * EXP( - alfg_i * z_w )
                IF (z_w < z1can) THEN
                   fact_c = xlv_i
                ELSE
                   fact_c = xlv_i * EXP( - alfc_i * (z_w - z1can) )
                END IF
                qfx(i,k,j) = fact_g * grnqfx(i,j) + fact_c * canqfx(i,j)
            
!!              if(hfx(i,k,j).ne.0. .or. qfx(i,k,j) .ne. 0.)then
!!                  write(msg,1)i,k,j,hfx(i,k,j),qfx(i,k,j)
!!1                 format('tend:',3i6,2e11.3)
!!                  call message(msg)
!               endif
            else if (fire_sfc_flx .eq. 1) then !Truncated Gaussian scheme
               ! heat flux
               fact_g = prop_heat(i,k,j) * cp_i
               IF ( z_w < z1can ) THEN
                  fact_c = cp_i
               ELSE
                  fact_c = cp_i * prop_heat(i,k,j)
               END IF
               hfx(i,k,j) = fact_g * grnhfx(i,j) + fact_c * canqfx(i,j)
            
               ! vapor flux
               fact_g = prop_heat(i,k,j) * xlv_i
               IF (z_w < z1can) THEN
                  fact_c = xlv_i
               ELSE
                  fact_c = xlv_i * prop_heat(i,k,j)
               END IF
               qfx(i,k,j) = fact_g * grnqfx(i,j) + fact_c * canqfx(i,j)

            else
               call wrf_error_fatal('Invalid fire heat release option: check fire_sfc_flx namelist option')
            end if

         END DO
      END DO
   END DO

! --- add flux divergence to tendencies
!
!   multiply by dry air mass (mu) to eliminate the need to
!   call sr. calculate_phy_tend (in dyn_em/module_em.F)

   DO j = j_st,j_en
      DO k = k_st,k_en-1
         DO i = i_st,i_en

            rho_i = 1./rho(i,k,j)

            rthfrten(i,k,j) = - (c1h(k)*mu(i,j)+c2h(k)) * rho_i * (hfx(i,k+1,j)-hfx(i,k,j)) / dz8w(i,k,j)
            rqvfrten(i,k,j) = - (c1h(k)*mu(i,j)+c2h(k)) * rho_i * (qfx(i,k+1,j)-qfx(i,k,j)) / dz8w(i,k,j)

         END DO
      END DO
   END DO

   call print_3d_stats(its,ite,kts,kte,jts,jte,ims,ime,kms,kme,jms,jme,rthfrten,'fire_tendency:rthfrten')
   call print_3d_stats(its,ite,kts,kte,jts,jte,ims,ime,kms,kme,jms,jme,rqvfrten,'fire_tendency:rqvfrten')

   RETURN

END SUBROUTINE fire_tendency

SUBROUTINE tg_dist(ims,ime, kms,kme, jms,jme, &
                   i_st,i_en, j_st,j_en, k_st,k_en, dz8w, &
                   fire_peak_hgt,fire_tg_ub,fire_ext_depth,z_at_w,zs, &
                   prop)
   !!!! Truncated Gaussian Distribution Subroutine for Heat and Smoke Release
   !!!! Developed by: Kasra Shamsaei (Univ. of Nevada, Reno) and Tim Juliano (NCAR/RAL)
   !!!! Supervised by: Branko Kosovic (NCAR/RAL)

   IMPLICIT NONE

   INTEGER, INTENT(in) :: ims,ime, kms,kme, jms,jme
   INTEGER, INTENT(in) :: i_st,i_en, j_st,j_en, k_st,k_en     !loop indices
   REAL, INTENT(in), DIMENSION( ims:ime,kms:kme,jms:jme ) :: dz8w   ! dz across w-lvl
   REAL, INTENT(in) :: fire_peak_hgt    !peak heat release height for Truncated Gaussian scheme
   REAL, INTENT(in) :: fire_tg_ub       !upper bound for the Truncated Gaussian scheme
   REAL, INTENT(in) :: fire_ext_depth   !extinction depth surface fire heat (m)
   REAL, INTENT(in), DIMENSION( ims:ime,kms:kme,jms:jme ) :: z_at_w ! m abv sealvl
   REAL, INTENT(in), DIMENSION( ims:ime,jms:jme ) :: zs  ! topography (m abv sealvl)
   REAL, INTENT(out), DIMENSION( i_st:i_en,k_st:k_en,j_st:j_en ) :: prop !proportion of heat or smoke to be released

   ! --- local for Truncated Gaussian
   INTEGER :: i,j,k

   REAL, PARAMETER :: acoef = 167./148., bcoef = 11./109., fire_tg_lb = 0.
   REAL :: xia, xib
   REAL :: phi_a, phi_b
   REAL :: xi
   REAL :: dz
   REAL :: z_w
   REAL :: prop_temp

   xia = (fire_tg_lb-fire_peak_hgt)/(0.5*fire_ext_depth)
   xib = (fire_tg_ub-fire_peak_hgt)/(0.5*fire_ext_depth)

   phi_a = 0.5*(1.+tanh(acoef*xia+bcoef*(xia**3)))
   phi_b = 0.5*(1.+tanh(acoef*xib+bcoef*(xib**3)))

   DO j = j_st,j_en
      DO k = k_st,k_en
         DO i = i_st,i_en

            xi=(z_w-fire_peak_hgt)/(0.5*fire_ext_depth)

            prop_temp = 0.5*(acoef+3.*bcoef*(xi**2))/(0.5*fire_ext_depth)*(1.-(tanh(acoef*xi+bcoef*(xi**3)))**2)
            prop_temp = prop_temp / (phi_b-phi_a)
   
            !discretize the continuous function
            if (k .eq. k_st) then
               dz = 0.5 * dz8w(i,k,j)
            else if (k .eq. k_en) then
               dz = 0.5 * dz8w(i,k-1,j)
            else
               dz = 0.5 * (dz8w(i,k,j) + dz8w(i,k-1,j))
            end if

            prop(i,k,j) = prop_temp * dz

         END DO
      END DO
   END DO

END SUBROUTINE tg_dist

!
!***
!

end module module_fr_fire_atm
