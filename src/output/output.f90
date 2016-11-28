!=================================================================================================================================
! Copyright (c) 2010-2016  Prof. Claus-Dieter Munz 
! This file is part of FLEXI, a high-order accurate framework for numerically solving PDEs with discontinuous Galerkin methods.
! For more information see https://www.flexi-project.org and https://nrg.iag.uni-stuttgart.de/
!
! FLEXI is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License 
! as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.
!
! FLEXI is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty
! of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License v3.0 for more details.
!
! You should have received a copy of the GNU General Public License along with FLEXI. If not, see <http://www.gnu.org/licenses/>.
!=================================================================================================================================
#include "flexi.h"

!==================================================================================================================================
!> Provides routines for visualization and ASCII output of time series. Initializes some variables used for HDF5 output.
!==================================================================================================================================
MODULE MOD_Output
! MODULES
USE MOD_ReadInTools
USE ISO_C_BINDING
IMPLICIT NONE

INTERFACE
  FUNCTION get_userblock_size()
      INTEGER :: get_userblock_size
  END FUNCTION 
END INTERFACE

INTERFACE
  FUNCTION get_inifile_size(filename) BIND(C)
      USE ISO_C_BINDING, ONLY: C_CHAR,C_INT
      CHARACTER(KIND=C_CHAR) :: filename(*)
      INTEGER(KIND=C_INT)    :: get_inifile_size
  END FUNCTION get_inifile_size
END INTERFACE

INTERFACE
  SUBROUTINE insert_userblock(filename,inifilename) BIND(C)
      USE ISO_C_BINDING, ONLY: C_CHAR
      CHARACTER(KIND=C_CHAR) :: filename(*)
      CHARACTER(KIND=C_CHAR) :: inifilename(*)
  END SUBROUTINE insert_userblock
END INTERFACE

!----------------------------------------------------------------------------------------------------------------------------------
! GLOBAL VARIABLES
!----------------------------------------------------------------------------------------------------------------------------------

! Output format for state visualization
INTEGER,PARAMETER :: OUTPUTFORMAT_NONE         = 0
INTEGER,PARAMETER :: OUTPUTFORMAT_TECPLOT      = 1
INTEGER,PARAMETER :: OUTPUTFORMAT_TECPLOTASCII = 2
INTEGER,PARAMETER :: OUTPUTFORMAT_PARAVIEW     = 3

! Output format for ASCII data files
INTEGER,PARAMETER :: ASCIIOUTPUTFORMAT_CSV     = 0
INTEGER,PARAMETER :: ASCIIOUTPUTFORMAT_TECPLOT = 1

INTERFACE DefineParametersOutput
  MODULE PROCEDURE DefineParametersOutput
END INTERFACE

INTERFACE InitOutput
  MODULE PROCEDURE InitOutput
END INTERFACE

INTERFACE PrintStatusLine
  MODULE PROCEDURE PrintStatusLine
END INTERFACE

INTERFACE Visualize
  MODULE PROCEDURE Visualize
END INTERFACE

INTERFACE InitOutputToFile
  MODULE PROCEDURE InitOutputToFile
END INTERFACE

INTERFACE OutputToFile
  MODULE PROCEDURE OutputToFile
END INTERFACE

INTERFACE FinalizeOutput
  MODULE PROCEDURE FinalizeOutput
END INTERFACE

PUBLIC:: InitOutput,PrintStatusLine,Visualize,InitOutputToFile,OutputToFile,FinalizeOutput
!==================================================================================================================================

PUBLIC::DefineParametersOutput
CONTAINS

!==================================================================================================================================
!> Define parameters 
!==================================================================================================================================
SUBROUTINE DefineParametersOutput()
! MODULES
USE MOD_ReadInTools ,ONLY: prms,addStrListEntry
IMPLICIT NONE
!==================================================================================================================================
CALL prms%SetSection("Output")
CALL prms%CreateIntOption(          'NVisu',       "Polynomial degree at which solution is sampled for visualization.")
CALL prms%CreateIntOption(          'NOut',        "Polynomial degree at which solution is written. -1: NOut=N, >0: NOut", '-1')
CALL prms%CreateStringOption(       'ProjectName', "Name of the current simulation (mandatory).")
CALL prms%CreateLogicalOption(      'Logging',     "Write log files containing debug output.", '.FALSE.')
CALL prms%CreateLogicalOption(      'ErrorFiles',  "Write error files containing error output.", '.TRUE.')
CALL prms%CreateIntFromStringOption('OutputFormat',"File format for visualization: None, Tecplot, TecplotASCII, ParaView. "//&
                                                 " Note: Tecplot output is currently unavailable due to licensing issues.", 'None')
CALL addStrListEntry('OutputFormat','none',        OUTPUTFORMAT_NONE)
CALL addStrListEntry('OutputFormat','tecplot',     OUTPUTFORMAT_TECPLOT)
CALL addStrListEntry('OutputFormat','tecplotascii',OUTPUTFORMAT_TECPLOTASCII)
CALL addStrListEntry('OutputFormat','paraview',    OUTPUTFORMAT_PARAVIEW)
CALL prms%CreateIntFromStringOption('ASCIIOutputFormat',"File format for ASCII files, e.g. body forces: CSV, Tecplot."&
                                                       , 'CSV')
CALL addStrListEntry('ASCIIOutputFormat','csv',    ASCIIOUTPUTFORMAT_CSV)
CALL addStrListEntry('ASCIIOutputFormat','tecplot',ASCIIOUTPUTFORMAT_TECPLOT)
CALL prms%CreateLogicalOption(      'doPrintStatusLine','Print: percentage of time, ...', '.FALSE.')
CALL prms%CreateLogicalOption(      'ColoredOutput','Colorize stdout', '.TRUE.')
END SUBROUTINE DefineParametersOutput

!==================================================================================================================================
!> Initialize all output variables.
!==================================================================================================================================
SUBROUTINE InitOutput()
! MODULES
USE MOD_Globals
USE MOD_Preproc
USE MOD_Output_Vars
USE MOD_ReadInTools       ,ONLY:GETSTR,GETLOGICAL,GETINT,GETINTFROMSTR
USE MOD_StringTools       ,ONLY:INTTOSTR
USE MOD_Interpolation     ,ONLY:GetVandermonde
USE MOD_Interpolation_Vars,ONLY:InterpolationInitIsDone,NodeTypeVISU,NodeType
USE ISO_C_BINDING,         ONLY: C_NULL_CHAR
IMPLICIT NONE
!----------------------------------------------------------------------------------------------------------------------------------
! INPUT/OUTPUT VARIABLES
!----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
INTEGER                        :: OpenStat
CHARACTER(LEN=8)               :: StrDate
CHARACTER(LEN=10)              :: StrTime
CHARACTER(LEN=255)             :: LogFile
INTEGER                        :: inifile_len
!==================================================================================================================================
IF ((.NOT.InterpolationInitIsDone).OR.OutputInitIsDone) THEN
  CALL CollectiveStop(__STAMP__,&
    'InitOutput not ready to be called or already called.')
END IF
SWRITE(UNIT_StdOut,'(132("-"))')
SWRITE(UNIT_stdOut,'(A)') ' INIT OUTPUT...'

NVisu=GETINT('NVisu',INTTOSTR(PP_N))

! Gauss/Gl -> Visu : computation -> visualization
ALLOCATE(Vdm_GaussN_NVisu(0:NVisu,0:PP_N))
CALL GetVandermonde(PP_N,NodeType,NVisu,NodeTypeVISU,Vdm_GaussN_NVisu)

! Output polynomial degree (to reduce storage,e.g.in case of overintegration)
NOut=GETINT('NOut','-1') ! -1: PP_N(off), >0:custom
IF(NOut.EQ.-1)THEN
  NOut=PP_N
END IF
! Get Vandermonde for output changebasis
IF(NOut.NE.PP_N)THEN
  ALLOCATE(Vdm_N_NOut(0:NOut,0:PP_N))
  CALL GetVandermonde(PP_N,NodeType,NOut,NodeType,Vdm_N_NOut,modal=.TRUE.)
END IF

! Name for all output files
ProjectName=GETSTR('ProjectName')
Logging    =GETLOGICAL('Logging')
ErrorFiles =GETLOGICAL('ErrorFiles')

doPrintStatusLine=GETLOGICAL("doPrintStatusLine")


IF (MPIRoot) THEN
  ! read userblock length in bytes from data section of flexi-executable
  userblock_len = get_userblock_size()
  inifile_len = get_inifile_size(TRIM(ParameterFile)//C_NULL_CHAR)
  ! prepare userblock file
  CALL insert_userblock(TRIM(UserBlockTmpFile)//C_NULL_CHAR,TRIM(ParameterFile)//C_NULL_CHAR)
  INQUIRE(FILE=TRIM(UserBlockTmpFile),SIZE=userblock_total_len)
END IF

WRITE(ErrorFileName,'(A,A8,I6.6,A4)')TRIM(ProjectName),'_ERRORS_',myRank,'.out'

! Get output format for state visualization
OutputFormat = GETINTFROMSTR('OutputFormat')
! Get output format for ASCII data files
ASCIIOutputFormat = GETINTFROMSTR('ASCIIOutputFormat')

! Open file for logging
IF(Logging)THEN
  WRITE(LogFile,'(A,A1,I6.6,A4)')TRIM(ProjectName),'_',myRank,'.log'
  OPEN(UNIT=UNIT_logOut,  &
       FILE=LogFile,      &
       STATUS='UNKNOWN',  &
       ACTION='WRITE',    &
       POSITION='APPEND', &
       IOSTAT=OpenStat)
  CALL DATE_AND_TIME(StrDate,StrTime)
  WRITE(UNIT_logOut,*)
  WRITE(UNIT_logOut,'(132("#"))')
  WRITE(UNIT_logOut,*)
  WRITE(UNIT_logOut,*)'STARTED LOGGING FOR PROC',myRank,' ON ',StrDate(7:8),'.',StrDate(5:6),'.',StrDate(1:4),' | ',&
                      StrTime(1:2),':',StrTime(3:4),':',StrTime(5:10)
END IF  ! Logging

OutputInitIsDone =.TRUE.
SWRITE(UNIT_stdOut,'(A)')' INIT OUTPUT DONE!'
SWRITE(UNIT_StdOut,'(132("-"))')
END SUBROUTINE InitOutput

SUBROUTINE PrintStatusLine(t,dt,tStart,tEnd) 
!----------------------------------------------------------------------------------------------------------------------------------!
! description
!----------------------------------------------------------------------------------------------------------------------------------!
! MODULES                                                                                                                          !
USE MOD_Globals
USE MOD_PreProc
USE MOD_Output_Vars , ONLY: doPrintStatusLine
#if FV_ENABLED
USE MOD_Mesh_Vars   , ONLY: nGlobalElems
USE MOD_FV_Vars     , ONLY: FV_Elems
USE MOD_Analyze_Vars, ONLY: totalFV_nElems
#endif
!----------------------------------------------------------------------------------------------------------------------------------!
! insert modules here
!----------------------------------------------------------------------------------------------------------------------------------!
IMPLICIT NONE
! INPUT / OUTPUT VARIABLES 
REAL,INTENT(IN) :: t,dt,tStart,tEnd
!----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
#if FV_ENABLED
INTEGER :: FVcounter
REAL    :: FV_percent
#endif
REAL    :: percent,time_remaining,mins,secs,hours
!==================================================================================================================================
#if FV_ENABLED
FVcounter = SUM(FV_Elems)
totalFV_nElems = totalFV_nElems + FVcounter ! counter for output of FV amount during analyze
#endif

IF(.NOT.doPrintStatusLine) RETURN

#if FV_ENABLED && MPI
CALL MPI_ALLREDUCE(MPI_IN_PLACE,FVcounter,1,MPI_INTEGER,MPI_SUM,MPI_COMM_WORLD,iError)
#endif

IF(MPIroot)THEN
#ifdef INTEL
  OPEN(UNIT_stdOut,CARRIAGECONTROL='fortran')
#endif
  percent = (t-tStart) / (tend-tStart) 
  CALL CPU_TIME(time_remaining)
  IF (percent.GT.0.0) time_remaining = time_remaining/percent - time_remaining
  percent = percent*100.
  secs = MOD(time_remaining,60.)
  time_remaining = time_remaining / 60
  mins = MOD(time_remaining,60.)
  time_remaining = time_remaining / 60
  hours = MOD(time_remaining,24.)
#if FV_ENABLED
  FV_percent = REAL(FVcounter) / nGlobalElems * 100.
  WRITE(UNIT_stdOut,'(F7.2,A5)',ADVANCE='NO') FV_percent, '% FV '
#endif
  WRITE(UNIT_stdOut,'(A,E10.4,A,E10.4,A,F6.2,A,I4,A1,I0.2,A1,I0.2,A1)',ADVANCE='NO') 'Time = ', t, &
      ' dt = ', dt, '  ', percent, '% complete, est. Time Remaining = ',INT(hours),':',INT(mins),':',INT(secs), ACHAR(13)
#ifdef INTEL
  CLOSE(UNIT_stdOut)
#endif
END IF
END SUBROUTINE PrintStatusLine

!==================================================================================================================================
!> Supersample DG dataset at (equidistant) visualization points and output to file.
!> Currently only Paraview binary format is supported.
!> Tecplot support has been removed due to licensing issues (possible GPL incompatibility).
!==================================================================================================================================
SUBROUTINE Visualize(OutputTime,U)
! MODULES
USE MOD_Globals
USE MOD_PreProc
USE MOD_Equation_Vars,ONLY:StrVarNames
USE MOD_Output_Vars,ONLY:ProjectName,OutputFormat
USE MOD_Mesh_Vars  ,ONLY:Elem_xGP,nElems
USE MOD_Output_Vars,ONLY:NVisu,Vdm_GaussN_NVisu
USE MOD_ChangeBasis,ONLY:ChangeBasis3D
USE MOD_VTK        ,ONLY:WriteDataToVTK3D,WriteVTKMultiBlockDataSet
#if FV_ENABLED
USE MOD_FV_Vars    ,ONLY: FV_Elems
#if FV_RECONSTRUCT
USE MOD_FV_Vars    ,ONLY: FV_dx_XI_L,FV_dx_XI_R,FV_dx_ETA_L,FV_dx_ETA_R,FV_dx_ZETA_L,FV_dx_ZETA_R
USE MOD_FV_Vars    ,ONLY: gradUxi,gradUeta,gradUzeta
#endif
USE MOD_EOS        ,ONLY: PrimToCons,ConsToPrim
USE MOD_FV_Basis
USE MOD_Indicator_Vars ,ONLY: IndValue
#endif
IMPLICIT NONE
!----------------------------------------------------------------------------------------------------------------------------------
! INPUT/OUTPUT VARIABLES
REAL,INTENT(IN)               :: OutputTime               !< simulation time of output
REAL,INTENT(IN)               :: U(PP_nVar,0:PP_N,0:PP_N,0:PP_N,1:nElems) !< solution vector to be visualized
!----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
INTEGER                       :: iElem,FV_iElem,DG_iElem,PP_nVar_loc,nFV_Elems,iVar
REAL,ALLOCATABLE              :: Coords_NVisu(:,:,:,:,:) 
REAL,ALLOCATABLE              :: U_NVisu(:,:,:,:,:)
CHARACTER(LEN=255)            :: FileString_DG
#if FV_ENABLED
CHARACTER(LEN=255)            :: FileString_FV
CHARACTER(LEN=255)            :: FileString_multiblock
INTEGER                       :: i,j,k,FV_NVisu,iii,jjj,kkk,ii,jj,kk
REAL                          :: UPrim(1:PP_nVarPrim)
REAL                          :: UPrim2(1:PP_nVarPrim)
REAL,ALLOCATABLE              :: FV_Coords_NVisu(:,:,:,:,:)
REAL,ALLOCATABLE              :: FV_U_NVisu(:,:,:,:,:)
REAL,ALLOCATABLE              :: Vdm_GaussN_FV_NVisu(:,:)
#endif
CHARACTER(LEN=255),ALLOCATABLE:: StrVarNames_loc(:)
#if FV_ENABLED && FV_RECONSTRUCT            
REAL                          :: dx,dy,dz
#endif
!==================================================================================================================================
IF(outputFormat.LE.0) RETURN
! Specify output names

nFV_Elems = 0
PP_nVar_loc=PP_nVar
#if FV_ENABLED
PP_nVar_loc=PP_nVar+2
DO iElem=1,nElems
  IF (FV_Elems(iElem).GT.0) nFV_Elems = nFV_Elems + 1 
END DO
FV_NVisu = (PP_N+1)*2-1
ALLOCATE(FV_U_NVisu(PP_nVar_loc,0:FV_NVisu,0:FV_NVisu,0:FV_NVisu,1:nFV_Elems))
ALLOCATE(FV_Coords_NVisu(1:3,0:FV_NVisu,0:FV_NVisu,0:FV_NVisu,1:nFV_Elems))
ALLOCATE(Vdm_GaussN_FV_NVisu(0:FV_NVisu,0:PP_N))
CALL FV_Build_VisuVdm(PP_N,Vdm_GaussN_FV_NVisu)
#endif
ALLOCATE(U_NVisu(PP_nVar_loc,0:NVisu,0:NVisu,0:NVisu,1:(nElems-nFV_Elems)))
U_NVisu = 0.
ALLOCATE(Coords_NVisu(1:3,0:NVisu,0:NVisu,0:NVisu,1:(nElems-nFV_Elems)))

DG_iElem=0; FV_iElem=0
DO iElem=1,nElems
#if FV_ENABLED
  IF (FV_Elems(iElem).EQ.0) THEN ! DG Element
#endif
    DG_iElem = DG_iElem+1
    ! Create coordinates of visualization points
    CALL ChangeBasis3D(3,PP_N,NVisu,Vdm_GaussN_NVisu,Elem_xGP(1:3,:,:,:,iElem),Coords_NVisu(1:3,:,:,:,DG_iElem))
    ! Interpolate solution onto visu grid
    CALL ChangeBasis3D(PP_nVar,PP_N,NVisu,Vdm_GaussN_NVisu,U(1:PP_nVar,:,:,:,iElem),U_NVisu(1:PP_nVar,:,:,:,DG_iElem))
#if FV_ENABLED
    U_NVisu(PP_nVar_loc-1,:,:,:,DG_iElem) = IndValue(iElem)
    U_NVisu(PP_nVar_loc,:,:,:,DG_iElem) = FV_Elems(iElem)
  ELSE 
    FV_iElem = FV_iElem+1

    CALL ChangeBasis3D(3,PP_N,FV_NVisu,Vdm_GaussN_FV_NVisu,Elem_xGP(1:3,:,:,:,iElem),FV_Coords_NVisu(1:3,:,:,:,FV_iElem))
    DO k=0,PP_N; DO j=0,PP_N; DO i=0,PP_N
      CALL ConsToPrim(UPrim ,U(:,i,j,k,iElem))
      DO kk=0,1; DO jj=0,1; DO ii=0,1
        kkk=k*2+kk; jjj=j*2+jj; iii=i*2+ii
#if FV_RECONSTRUCT            
        dx = MERGE(  -FV_dx_XI_L(i,j,k,iElem),  FV_dx_XI_R(i,j,k,iElem),ii.EQ.0)
        dy = MERGE( -FV_dx_ETA_L(i,j,k,iElem), FV_dx_ETA_R(i,j,k,iElem),jj.EQ.0)
        dz = MERGE(-FV_dx_ZETA_L(i,j,k,iElem),FV_dx_ZETA_R(i,j,k,iElem),kk.EQ.0)
        UPrim2 = UPrim + gradUxi(:,j,k,i,iElem) * dx + gradUeta(:,i,k,j,iElem) * dy + gradUzeta(:,i,j,k,iElem) * dz
#else
        UPrim2 = UPrim
#endif                                                                  
        CALL PrimToCons(UPrim2(1:PP_nVarPrim), FV_U_NVisu(:,iii,jjj,kkk,FV_iElem))
      END DO; END DO; END DO
    END DO; END DO; END DO
    FV_U_NVisu(PP_nVar_loc-1,:,:,:,FV_iElem) = IndValue(iElem)
    FV_U_NVisu(PP_nVar_loc,:,:,:,FV_iElem) = FV_Elems(iElem)
  END IF
#endif
END DO !iElem

ALLOCATE(StrVarNames_loc(PP_nVar_loc))
DO iVar=1,PP_nVar
  StrVarNames_loc(iVar) = StrVarNames(iVar) 
END DO ! iVar=1,PP_nVar
#if FV_ENABLED
  StrVarNames_loc(PP_nVar_loc-1) = "IndValue"
  StrVarNames_loc(PP_nVar_loc  ) = "FV_Elems"
#endif

! Visualize data
SELECT CASE(OutputFormat)
CASE(OUTPUTFORMAT_TECPLOT)
  STOP 'Tecplot output removed due to license issues (possible GPL incompatibility).'
CASE(OUTPUTFORMAT_TECPLOTASCII)
  STOP 'Tecplot output removed due to license issues (possible GPL incompatibility).'
CASE(OUTPUTFORMAT_PARAVIEW)
#if FV_ENABLED                            
  FileString_DG=TRIM(TIMESTAMP(TRIM(ProjectName)//'_DG',OutputTime))//'.vtu'
#else
  FileString_DG=TRIM(TIMESTAMP(TRIM(ProjectName)//'_Solution',OutputTime))//'.vtu'
#endif
  CALL WriteDataToVTK3D(        NVisu,nElems-nFV_Elems,PP_nVar_loc,StrVarNames_loc,Coords_NVisu(1:3,:,:,:,:), &
                                U_NVisu,TRIM(FileString_DG))
#if FV_ENABLED                            
  FileString_FV=TRIM(TIMESTAMP(TRIM(ProjectName)//'_FV',OutputTime))//'.vtu'
  CALL WriteDataToVTK3D(        FV_NVisu,nFV_Elems,PP_nVar_loc,StrVarNames_loc,FV_Coords_NVisu(1:3,:,:,:,:), &
                                FV_U_NVisu,TRIM(FileString_FV))

  IF (MPIRoot) THEN                   
    ! write multiblock file
    FileString_multiblock=TRIM(TIMESTAMP(TRIM(ProjectName)//'_Solution',OutputTime))//'.vtm'
    CALL WriteVTKMultiBlockDataSet(FileString_multiblock,FileString_DG,FileString_FV)
  ENDIF
#endif
END SELECT

DEALLOCATE(U_NVisu)
DEALLOCATE(Coords_NVisu)
#if FV_ENABLED
DEALLOCATE(FV_U_NVisu)
DEALLOCATE(FV_Coords_NVisu)
DEALLOCATE(Vdm_GaussN_FV_NVisu)
#endif
END SUBROUTINE Visualize


!==================================================================================================================================
!> Creates or opens file for structured output of data time series in comma seperated value or Tecplot ASCII format.
!> Default is comma seperated value.
!> Searches the file for a dataset at restart time and tries to resume at this point.
!> Otherwise a new file is created.
!==================================================================================================================================
SUBROUTINE InitOutputToFile(Filename,ZoneName,nVar,VarNames,lastLine)
! MODULES
USE MOD_Globals
USE MOD_Restart_Vars, ONLY: RestartTime
USE MOD_Output_Vars,  ONLY: ProjectName,ASCIIOutputFormat
IMPLICIT NONE
!----------------------------------------------------------------------------------------------------------------------------------
! INPUT/OUTPUT VARIABLES
CHARACTER(LEN=*),INTENT(IN)   :: FileName                 !< file to be written, without data type extension
CHARACTER(LEN=*),INTENT(IN)   :: ZoneName                 !< name of zone (e.g. names of boundary conditions), used for tecplot
INTEGER,INTENT(IN)            :: nVar                     !< number of variables
CHARACTER(LEN=*),INTENT(IN)   :: VarNames(nVar)           !< variable names to be written
REAL,INTENT(OUT),OPTIONAL     :: lastLine(nVar+1)         !< last written line to search for, when appending to the file 
!----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
INTEGER                        :: stat                         !< File IO status
INTEGER                        :: ioUnit,i
REAL                           :: dummytime                    !< Simulation time read from file
LOGICAL                        :: fileExists                   !< marker if file exists and is valid
CHARACTER(LEN=255)             :: FileName_loc                 ! FileName with data type extension
!==================================================================================================================================
IF(.NOT.MPIRoot) RETURN
IF(PRESENT(lastLine)) lastLine=-HUGE(1.)

! Append data type extension to FileName
IF (ASCIIOutputFormat.EQ.ASCIIOUTPUTFORMAT_CSV) THEN
  FileName_loc = TRIM(FileName)//'.csv'
ELSE
  FileName_loc = TRIM(FileName)//'.dat'
END IF

! Check for file
INQUIRE(FILE = TRIM(Filename_loc), EXIST = fileExists)
IF(RestartTime.LT.0.0) fileExists=.FALSE.
!! File processing starts here open old and extratct information or create new file.
ioUnit=GETFREEUNIT()

IF(fileExists)THEN ! File exists and append data
  OPEN(UNIT     = ioUnit             , &
       FILE     = TRIM(Filename_loc) , &
       FORM     = 'FORMATTED'        , &
       STATUS   = 'OLD'              , &
       POSITION = 'APPEND'           , &
       RECL     = 50000              , &
       IOSTAT = stat                 )
  IF(stat.NE.0)THEN
    WRITE(UNIT_stdOut,*)' File '//TRIM(FileName_loc)// ' is invalid. Rewriting file...'
    fileExists=.FALSE.
  END IF
END IF

IF(fileExists)THEN
  ! If we have a restart we need to find the position from where to move on.
  ! Read the values from the previous analyse interval, get the CPUtime
  WRITE(UNIT_stdOut,*)' Opening file '//TRIM(FileName_loc)
  WRITE(UNIT_stdOut,'(A)',ADVANCE='NO')'Searching for time stamp...'

  REWIND(ioUnit)
  DO i=1,4
    READ(ioUnit,*,IOSTAT=stat)
    IF(stat.NE.0)THEN
      ! file is broken, rewrite
      fileExists=.FALSE.
      WRITE(UNIT_stdOut,'(A)',ADVANCE='YES')' failed. Writing new file.'
      EXIT
    END IF
  END DO
END IF

IF(fileExists)THEN
  ! Loop until we have found the position
  Dummytime = 0.0
  stat=0
  DO WHILE ((Dummytime.LT.RestartTime) .AND. (stat.EQ.0))
    READ(ioUnit,*,IOSTAT=stat) Dummytime
  END DO
  IF(stat.EQ.0)THEN
    ! read final dataset
    IF(PRESENT(lastLine))THEN
      BACKSPACE(ioUnit)
      READ(ioUnit,*,IOSTAT=stat) lastLine
    END IF
    BACKSPACE(ioUnit)
    ENDFILE(ioUnit) ! delete from here to end of file
    WRITE(UNIT_stdOut,'(A,ES15.5)',ADVANCE='YES')' successfull. Resuming file at time ',Dummytime
  ELSE
    WRITE(UNIT_stdOut,'(A)',ADVANCE='YES')' failed. Appending data to end of file.'
  END IF
END IF
CLOSE(ioUnit) ! outputfile

IF(.NOT.fileExists)THEN ! No restart create new file
  ioUnit=GETFREEUNIT()
  OPEN(UNIT   = ioUnit             ,&
       FILE   = TRIM(Filename_loc) ,&
       STATUS = 'UNKNOWN'          ,&
       ACCESS = 'SEQUENTIAL'       ,&
       IOSTAT = stat               )
  IF (stat.NE.0) THEN
    CALL abort(__STAMP__, &
      'ERROR: cannot open '//TRIM(Filename_loc))
  END IF
  ! Create a new file with the CSV or Tecplot header
  IF (ASCIIOutputFormat.EQ.ASCIIOUTPUTFORMAT_CSV) THEN
    WRITE(ioUnit,'(A)',ADVANCE='NO') 'Time'
    DO i=1,nVar
      WRITE(ioUnit,'(A)',ADVANCE='NO') ','//TRIM(VarNames(i))
    END DO
  ELSE
    WRITE(ioUnit,*)'TITLE="'//TRIM(ZoneName)//','//TRIM(ProjectName)//'"'
    WRITE(ioUnit,'(A)',ADVANCE='NO')'VARIABLES = "Time"'
    DO i=1,nVar
      WRITE(ioUnit,'(A)',ADVANCE='NO') ',"'//TRIM(VarNames(i))//'"'
    END DO
    WRITE(ioUnit,'(A)',ADVANCE='YES')
    WRITE(ioUnit,'(A)') 'ZONE T="'//TRIM(ZoneName)//','//TRIM(ProjectName)//'"'
  END IF
  CLOSE(ioUnit) ! outputfile
END IF
END SUBROUTINE InitOutputToFile


!==================================================================================================================================
!> Outputs formatted data into a text file.
!> Format is either comma seperated value or tecplot.
!==================================================================================================================================
SUBROUTINE OutputToFile(FileName,time,nVar,output)
! MODULES
USE MOD_Globals
USE MOD_Output_Vars,  ONLY: ASCIIOutputFormat
IMPLICIT NONE
!----------------------------------------------------------------------------------------------------------------------------------
! INPUT/OUTPUT VARIABLES
CHARACTER(LEN=*),INTENT(IN)   :: FileName                 !< name of file to be written, without data type extension
INTEGER,INTENT(IN)            :: nVar(2)                  !< 1: number of variables, 2: number of time samples
REAL,INTENT(IN)               :: time(nVar(2))            !< array of output times
REAL,INTENT(IN)               :: output(nVar(1)*nVar(2))  !< array containing one dataset vector per output time
!----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
INTEGER                        :: openStat                !< File IO status
CHARACTER(LEN=50)              :: formatStr               !< format string for the output and Tecplot header
INTEGER                        :: ioUnit,i,j
CHARACTER(LEN=255)             :: FileName_loc            ! FileName with data type extension
!==================================================================================================================================
! Append data type extension to FileName
IF (ASCIIOutputFormat.EQ.ASCIIOUTPUTFORMAT_CSV) THEN
  FileName_loc = TRIM(FileName)//'.csv'
ELSE
  FileName_loc = TRIM(FileName)//'.dat'
END IF

ioUnit=GETFREEUNIT()
OPEN(UNIT     = ioUnit             , &
     FILE     = TRIM(Filename_loc) , &
     FORM     = 'FORMATTED'        , &
     STATUS   = 'OLD'              , &
     POSITION = 'APPEND'           , &
     RECL     = 50000              , &
     IOSTAT = openStat             )
IF(openStat.NE.0) THEN
  CALL abort(__STAMP__, &
    'ERROR: cannot open '//TRIM(Filename_loc))
END IF
! Choose between CSV and tecplot output format
IF (ASCIIOutputFormat.EQ.ASCIIOUTPUTFORMAT_CSV) THEN
  DO i=1,nVar(2) ! Loop over all output times (equals lines to write)
    ! Write time stamp
    WRITE(ioUnit,'(E23.14E5)',ADVANCE='NO') time(i)
    DO j=1,nVar(1)-1 ! Loop over variables
      WRITE(ioUnit,'(1A,E23.14E5)',ADVANCE='NO') ",",output(nVar(1)*(i-1)+j)
    END DO ! 
    ! New line at last variable
    WRITE(ioUnit,'(1A,E23.14E5)',ADVANCE='YES') ",",output(nVar(1)*(i-1)+nVar(2))
  END DO
ELSE
  ! Create format string for the variable output
  WRITE(formatStr,'(A10,I2,A14)')'(E23.14E5,',nVar(1),'(1X,E23.14E5))'
  DO i=1,nVar(2)
    WRITE(ioUnit,formatstr) time(i),output(nVar(1)*(i-1)+1:nVar(1)*i)
  END DO
END IF
CLOSE(ioUnit) ! outputfile
END SUBROUTINE OutputToFile


!==================================================================================================================================
!> Deallocate arrays of output routines
!==================================================================================================================================
SUBROUTINE FinalizeOutput()
! MODULES
USE MOD_Output_Vars,ONLY:Vdm_GaussN_NVisu,Vdm_N_NOut,OutputInitIsDone
IMPLICIT NONE
!==================================================================================================================================
SDEALLOCATE(Vdm_GaussN_NVisu)
SDEALLOCATE(Vdm_N_NOut)
OutputInitIsDone = .FALSE.
END SUBROUTINE FinalizeOutput

END MODULE MOD_Output