/* using SAS macros to batch import csvs, summarize by group, create a final dataset,
and finally calculate some basic summary statistics and tables */

/* *** original data hasn't been made available *** */
/* *** test data following the same structure and format as the original dataset has been made available *** */

LIBNAME DIR '/home/u58705725/Project/Data'; /* set working directory */

/* create macro to read csv files from a directory */
%macro drive(dir, ext);
	%local cnt filrf rc did memcnt name;
	%let cnt=0;
	%let filrf=mydir;
	%let rc=%sysfunc(filename(filrf, &dir));
	%let did=%sysfunc(dopen(&filrf));

	%if &did ne 0 %then
		%do;
			%let memcnt=%sysfunc(dnum(&did));

			%do i=1 %to &memcnt;
				%let name=%qscan(%qsysfunc(dread(&did, &i)), -1, .);

				%if %qupcase(%qsysfunc(dread(&did, &i))) ne %qupcase(&name) %then
					%do;

						%if %superq(ext)=%superq(name) %then
							%do;
								%let cnt=%eval(&cnt+1);
								%put %qsysfunc(dread(&did, &i));

								proc import datafile="&dir\%qsysfunc(dread(&did,&i))" 
										out=DIR.dsn&cnt (KEEP=PID file_source_PrimaryAccel file_source_IMU 
										Timestamp minute_of_day hour_of_day Right_Wrist_Algorithm2_METs) dbms=csv replace;
									GETNAMES=YES;
									GUESSINGROWS=43200;
								run;

							%end;
					%end;
			%end;
		%end;
	%else
		%put &dir cannot be opened.;
	%let rc=%sysfunc(dclose(&did));
%mend drive;

/* run macro to read csv files from a directory */
%drive(/home/u58705725/Project/Data/, csv);

/* create macro to calculate percentages of time performing low-intensity, medium-intensity,
and high-intensity physical activity during every hour */

%macro mets;

%DO i=1 %to 9;

    PROC STDIZE DATA=DIR.dsn&i REPONLY METHOD=mean OUT=DIR.a&i;
        VAR Right_Wrist_Algorithm2_METs;
    RUN;

    DATA DIR.b&i;
        SET DIR.a&i;

        IF Right_Wrist_Algorithm2_METs < 1.5 THEN A=1;
        ELSE A=0;

        IF Right_Wrist_Algorithm2_METs >= 1.5 AND 
           Right_Wrist_Algorithm2_METs <= 2.99 THEN B=1;
        ELSE B=0;

        IF Right_Wrist_Algorithm2_METs > 2.99 THEN C=1;
        ELSE C=0;
    RUN;

    PROC SQL;
        CREATE TABLE DIR.c&i AS
        SELECT
        	PID,
        	file_source_PrimaryAccel,
			file_source_IMU,
            hour_of_day,
            SUM(A) AS lowt,
            SUM(B) AS mediumt,
            SUM(C) AS hight,
            COUNT(*) AS total
        FROM DIR.b&i
        GROUP BY hour_of_day;
    QUIT;


    PROC SQL;
        CREATE TABLE DIR.d&i AS
        SELECT DISTINCT *,
            (lowt/total * 100) AS lowp,
            (mediumt/total * 100) AS mediump,
            (hight/total * 100) AS highp
        FROM DIR.c&i;
    QUIT;

%END;

%mend;

/* run macro to calculate percentages of time performing low-intensity, medium-intensity,
and high-intensity physical activity during every hour */
%mets;

/* construct combined dataset here */
data DIR.mets;
	set DIR.d1-DIR.d9;
run;

/* inspect combined dataset before exporting */
PROC PRINT DATA=DIR.mets (obs=10) NOOBS;
RUN;

/* export combined dataset as csv */
proc export data=DIR.mets 
		outfile="/home/u58705725/Project/Data/mets.csv" dbms=csv;
run;

/* calculating log-ratios
ilr_j = sqrt((r_j * s_j) / (r_j + s_j)) * log(g(R_j) / g(S_j))
j The balance index. It identifies which split between groups of components you are calculating.
r_j Number of components in the numerator group R
s_j	Number of components in the denominator group S
R_j	The set of components assigned to the positive side of the balance.
S_j The set of components assigned to the negative side of the balance.
g(R_j) Geometric mean of the components in group R
g(S_j) Geometric mean of the components in group S

log-ratio 1
r_j = 1; s_j = 2
R_j = lowp
S_j = mediump, highp

log-ratio 2
r_j = 1; s_j = 1
R_j = mediump
S_j = highp
*/

DATA DIR.mets1;
	SET DIR.mets;
	rs12=sqrt(2/3); /* calculating component of isometric log-ratio 1; sqrt((r_j * s_j) / (r_j + s_j)); r_j = 1; s_j = 2 */
	rs11=sqrt(1/2); /* calculating component of isometric log-ratio 2; sqrt((r_j * s_j) / (r_j + s_j)); r_j = 1; s_j = 1 */
RUN;

PROC PRINT DATA=DIR.mets1 (obs=10) NOOBS;
RUN;

DATA DIR.mets2;
	SET DIR.mets1;
	gmean=geomean(mediump, highp); /* calculating component of isometric log-ratio 1; g(S_j);
	the set of components in S_j are mediump, highp */
RUN;

PROC PRINT DATA=DIR.mets2 (obs=10) NOOBS;
RUN;

DATA DIR.mets3;
	SET DIR.mets2;
	ilr1=rs12*log(lowp/gmean); /* log-ratios cannot be calculated for the compositions containing zeros */
	ilr2=rs11*log(mediump/highp); /* log-ratios cannot be calculated for the compositions containing zeros */
RUN;

PROC PRINT DATA=DIR.mets3 (obs=10) NOOBS;
RUN;

/* exporting final dataset */
DATA DIR.metsilr;
	SET DIR.mets3 (KEEP=PID file_source_PrimaryAccel file_source_IMU lowp mediump 
		highp ilr1 ilr2);
RUN;

PROC PRINT DATA=DIR.metsilr (obs=10) NOOBS;
RUN;

/* basic summary statistics - five number summary */
proc summary data=DIR.metsilr;
	var lowp mediump highp;
	CLASS PID;
	output out=DIR.metslmhp;
run;

/* basic summary statistics - observations per entity in the final dataset */
proc tabulate data=dir.metsilr;
	class PID;
	table PID;
RUN;

/* basic scatter plot */
proc sgscatter data=DIR.metsilr;
	matrix lowp mediump highp;
run;

/* basic histogram - overlapping normal and kernel densities */
PROC SGPLOT data=DIR.metsilr;
	HISTOGRAM highp;
	density highp / type=normal;
	density highp / type=kernel;
RUN;

/* save histogram plot as rtf */
ods graphics on;
ods listing close;
Options papersize=("11.69in", "16.54in");
options orientation=landscape;
ODS tagsets.rtf 
	file='/home/u58705725/Project/Data/Figure.rtf' 
	startpage=yes style=journal;

PROC SGPLOT data=DIR.metsilr;
	HISTOGRAM highp;
	density highp / type=normal;
	density highp / type=kernel;
RUN;

ODS tagsets.rtf close;
ods listing;
ods graphics off;