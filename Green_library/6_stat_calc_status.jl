using Dates, Printf

contain_filename(p::String, pat) = readdir(p) |> 
    t->filter(contains(pat), t) |> isempty |> v->!v

stage_wconf(x) = x > 0.0
stage_shotT(x) = x > 1.0
stage_shotA(x) = x >= 2.7
stage_shotD(x) = stage_shotA(x) || (round(UInt8, mod(x*10, 10)) & 0x01) > 0
stage_shotE(x) = stage_shotA(x) || (round(UInt8, mod(x*10, 10)) & 0x02) > 0
stage_shotN(x) = stage_shotA(x) || (round(UInt8, mod(x*10, 10)) & 0x04) > 0
stage_cglib(x) = x > 3.0
stage_cmprs(x) = x > 4.0
stage_fillI(x) = x > 5.0

function test_calculation_stage(path::String)
    fstage = 0.0;
    if isfile(joinpath(path, "writeconfig.flag"))
        fstage = 1.0
    end
    if stage_wconf(fstage) && isfile(joinpath(path, "shotT.flag"))
        fstage = 2.0;
    end
    if stage_shotT(fstage) && isfile(joinpath(path, "shotD.flag"))
        fstage += 0.1;
    end
    if stage_shotT(fstage) && isfile(joinpath(path, "shotE.flag"))
        fstage += 0.2;
    end
    if stage_shotT(fstage) && isfile(joinpath(path, "shotN.flag"))
        fstage += 0.4;
    end
    if round(fstage, digits=1) == 2.7
        fstage = 3.0 # finish all shot
    end
    if stage_shotA(fstage) && isfile(joinpath(path, "calcglib.flag"))
        fstage = 4.0
    end
    if stage_cglib(fstage) && isfile(joinpath(path, "compress.flag"))
        fstage = 5.0
    end
    if stage_cmprs(fstage) && isfile(joinpath(path, "fillinfo.flag"))
        fstage = 6.0
    end

    pstage = fstage;
    if (pstage == 0.0) && any(isdir, joinpath.(path, "shot".*["T", "D", "E", "N"]))
        pstage = 1.0; # write config
    end
    tdir = joinpath(path, "shotT", "OUTPUT_FILES", "DATABASES_MPI")
    if (pstage == 1.0) && isdir(tdir) && contain_filename(tdir, "proc")
        pstage = 2.0; # shotT
    end
    tdir = joinpath(path, "shotD", "OUTPUT_FILES", "DATABASES_MPI")
    if (pstage == 2.0) && stage_shotT(pstage) &&
        isdir(tdir) &&
        contain_filename(tdir, "proc")
        pstage += 0.1; # shotD
    end
    tdir = joinpath(path, "shotE", "OUTPUT_FILES", "DATABASES_MPI")
    if (pstage >= 2.0) && (pstage < 3.0) && stage_shotT(pstage) &&
        isdir(tdir) &&
        contain_filename(tdir, "proc")
        pstage += 0.2; # shotE
    end
    tdir = joinpath(path, "shotN", "OUTPUT_FILES", "DATABASES_MPI")
    if (pstage >= 2.0) && (pstage < 3.0) && stage_shotT(pstage) &&
        isdir(tdir) &&
        contain_filename(tdir, "proc")
        pstage += 0.4; # shotN
    end
    if round(pstage, digits=1) == 2.7
        pstage = 3.0 # finish all shot
    end
    if (pstage == 3.0) && stage_shotA(pstage) && contain_filename(path, r"glib_tmp[0-9]_[0-9]*\.bin")
        pstage = 4.0 # calc glib
    end
    if (pstage == 4.0) && stage_cglib(pstage) && contain_filename(path, r"glib_[0-9]*\.bin")
        pstage = 5.0 # compress glib
    end
    if (pstage == 5.0) && stage_cmprs(pstage) && isdir(joinpath(path, "tlibvar"))
        pstage = 6.0
    end
    return (fstage, pstage)
end

function status_symbol(f1::Bool, f2::Bool; lbdr::Bool=false, rbdr::Bool=false)
    style = ""
    if lbdr
        style *= "border-left: 1px solid #CCCCCC;"
    end
    if rbdr
        style *= "border-right: 1px solid #CCCCCC;"
    end

    if f1
        style *= "color:#0C8918;"
        textstr = "&#10003;"
    elseif f2
        style *= "color:#FF7500;"
        textstr = "&#8226;&#8226;&#8226;"
    else
        style *= "color:#BBBBBB;"
        textstr = ""
    end
    return "<td style=\"$(style)\">"*textstr*"</td>\n"
end

function translate_stage_code(fstage, pstage)
    str = ""
    str *= status_symbol(stage_wconf(fstage), stage_wconf(pstage))
    str *= status_symbol(stage_shotT(fstage), stage_shotT(pstage))
    str *= status_symbol(stage_shotD(fstage), stage_shotD(pstage), lbdr=true)
    str *= status_symbol(stage_shotE(fstage), stage_shotE(pstage))
    str *= status_symbol(stage_shotN(fstage), stage_shotN(pstage), rbdr=true)
    str *= status_symbol(stage_cglib(fstage), stage_cglib(pstage))
    str *= status_symbol(stage_cmprs(fstage), stage_cmprs(pstage))
    str *= status_symbol(stage_fillI(fstage), stage_fillI(pstage))
    return str;
end

glib_root = abspath("../../dat/glib/")
station_list = readdir() |> x->filter(startswith("batch"), x) |> x->readlines.(x) |>
    x->sort.(x) |> x->vcat(x...)
status_lines = map(station_list) do s
                    joinpath(glib_root, s) |> test_calculation_stage |>
                        x->translate_stage_code(x[1], x[2])
                    end
nowis = now()
timestr = @sprintf("%04d-%02d-%02d %02d:%02d:%02d", year(nowis), month(nowis),day(nowis),
    hour(nowis), minute(nowis), second(nowis))

open("glib_calc_status.html", "w") do io
    println(io, """
<!DOCTYPE html>
<html>
<head>
<title> Calculation Status </title>

<style>
table{
    border-collapse: collapse;
}
td,th{
    border-bottom: 1px solid #CCCCCC;
}
th{
    font-size: xx-large;
}
td{
    text-align: center;
    line-height: 2.0;
    font-size: x-large;
    font-family: monospace;
}
</style>
<body>
<table style="width:90%; margin:0 auto; background-color: #FFFFFF;">
<caption id="tcap" style="font-size: xx-large;">This file is generated before 2 minute ago</caption>
<script>
    var c = document.getElementById("tcap");
    var c2 = document.body
    var t1 = new Date("$(timestr)");
    var flag = false;
    function f(){
        var t2 = new Date();
        var dt = t2 - t1;
        if (dt>120000) {
            if(flag){
                c.style.backgroundColor="#BE002F";
                c2.style.backgroundColor="#BE002F";
                flag = false;
            } else {
                c.style.backgroundColor="#FFFFFF";
                c2.style.backgroundColor="#FFFFFF";
                c.style.color="#FFFFFF";
                flag = true;
            }
        } else {
            c.style.backgroundColor="#FFFFFF";
            c.style.color="#FFFFFF";
        }
    }
    setInterval(f, 500);
    f();
</script>
<tr>
    <th>id</th>
    <th>hash</th>
    <th>write config</th>
    <th>shot T</th>
    <th style="border-left: 1px solid #CCCCCC;">shot D</th>
    <th>shot E</th>
    <th style="border-right: 1px solid #CCCCCC;">shot N</th>
    <th>calculate</th>
    <th>compress</th>
    <th>fill travel time</th>
</tr>
""")

    for i = eachindex(station_list)
        spath = joinpath(glib_root, station_list[i])
        if isdir(spath)
            bindatas = filter(endswith(".bin"), readdir(spath))
            if isempty(bindatas)
                binstatus = "&nbsp;"
            else
                binstatus = "&#9993;"
            end
        else
            binstatus = ""
        end
        if isdir(spath) && isfile(joinpath(spath, "download.flag"))
            println(io, """<tr style="background-color: #EEEEEE">
            <td style="color:#000000">$(i)</td>
            <td style="color:#000000">$(binstatus)$(station_list[i])&#10004;</td>
            """*
            "<td style=\"color:#0C8918\">&#10003;</td>\n"^2*
            "<td style=\"color:#0C8918;border-left:1px solid #CCCCCC;\">&#10003;</td>\n"*
            "<td style=\"color:#0C8918\">&#10003;</td>\n"*
            "<td style=\"color:#0C8918;border-right:1px solid #CCCCCC;\">&#10003;</td>\n"*
            "<td style=\"color:#0C8918\">&#10003;</td>\n"^3*
            "\n</tr>\n")
            continue
        elseif isdir(spath) && isfile(joinpath(spath, "downloading.flag"))
            println(io, """<tr>
            <td style="color:#000000">$(i)</td>
            <td style="color:#FF7500">$(binstatus)$(station_list[i])&#8659;</td>
            """*
            "<td style=\"color:#0C8918\">&#10003;</td>\n"^2*
            "<td style=\"color:#0C8918;border-left:1px solid #CCCCCC;\">&#10003;</td>\n"*
            "<td style=\"color:#0C8918\">&#10003;</td>\n"*
            "<td style=\"color:#0C8918;border-right:1px solid #CCCCCC;\">&#10003;</td>\n"*
            "<td style=\"color:#0C8918\">&#10003;</td>\n"^3*
            "\n</tr>\n")
            continue
        end
        sline = translate_stage_code(test_calculation_stage(spath)...)
        if isdir(spath)
            if isfile(joinpath(spath, "slicemodel.flag"))
                tcolor = "#000000"
            else
                tcolor = "#FF7500"
            end
        else
            tcolor = "#BBBBBB"
        end
            println(io, """<tr>
    <td style="color:$tcolor">$(i)</td>
    <td style="color:$tcolor">$(binstatus)$(station_list[i])&nbsp;</td>
    $sline
</tr>
""")
    end

    println(io, """
</table>
</body>
</html>
""")
end