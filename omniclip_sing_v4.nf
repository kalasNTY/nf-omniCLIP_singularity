nextflow.enable.dsl = 2

// Define parameters
params.metadata = file("./metadata.csv")
params.db_file = file("./GRCh38_113.db")
params.bg_f = file("./bg_dat")
params.clip_f = file("./clip_dat")
params.genome_dir = file("./hg38_noChr")
params.gff_file = file("./Homo_sapiens.GRCh38.113.chromosome.3.gff3")
params.output_dir = file("./Results")
params.max_it = 1
params.nb_cores = 1
params.singularity_url = "library://kalasnty/omniclip/singularitycontainer:latest"
params.container_name = "omniclip_container.sif"

// Pull and store the Singularity container
process PULL_CONTAINER {
    output:
    path params.container_name, emit: container_pulled

    script:
    """
    singularity pull --arch amd64 ${params.container_name} ${params.singularity_url}
    """
}

// Generate database
process GENERATE_DB {
    input:
    path gff_file
    path db_file
    path container_pulled

    output:
    path db_file, emit: db_ch

    script:
    """
    if [ ! -f $db_file ]; then
    singularity run --bind ${launchDir}:/data --pwd /opt/omniCLIP ${container_pulled} \
    generateDB --gff-file /data/${gff_file.name} --db-file /data/${db_file.name}
    fi
    """
}

// Parse background data

process PARSING_BG {
    publishDir params.output_dir, mode: 'copy'
    input:
    path db_file
    path genome_dir
    path bg_file
    path bg_f
    path container_pulled


    output:
    path bg_dat, emit: bg_dat_ch

    script:
    """
    if [ ! -f $bg_f ]; then
    singularity run --bind ${launchDir}:/data --pwd /opt/omniCLIP ${container_pulled} \
    parsingBG --db-file /data/${db_file.name} --genome-dir /data/${genome_dir.name} \
    ${bg_file.collect { "--bg-files /data/Input/${it.name}" }.join(" ")} --out-file /data/${bg_f.name}
    fi
    """
}


// Parse CLIP data
process PARSING_CLIP {
    publishDir params.output_dir, mode: 'copy'

    input:
    path db_file
    path genome_dir
    path clip_file
    path clip_f
    path container_pulled

    output:
    path clip_dat, emit: clip_dat_ch

    script:
    """
    if [ ! -f $clip_f ]; then
    singularity run --bind ${launchDir}:/data --pwd /opt/omniCLIP ${container_pulled} \
    parsingCLIP --db-file /data/${db_file.name} --genome-dir /data/${genome_dir.name} \
    ${clip_file.collect { "--clip-files /data/Input/${it.name}" }.join(" ")} --out-file /data/${clip_f.name}
    fi
    """
}

// Run omniCLIP analysis
process RUN_OMNICLIP {
    input:
    path db_file
    path bg_dat_ch
    path clip_dat_ch
    path output_dir 
    val max_it 
    val nb_cores
    path container_pulled

    output:
    path output_dir

    script:
    """
    singularity run --bind ${launchDir}:/data --pwd /opt/omniCLIP ${container_pulled} \
    run_omniCLIP --db-file /data/${db_file.name} --bg-dat /data/${bg_dat_ch.name} --clip-dat /data/${clip_dat_ch.name} \
    --out-dir /data/${output_dir.name} --max-it ${params.max_it} --nb-cores ${params.nb_cores}
    """
}

workflow {
    def container_pulled = PULL_CONTAINER()

    // Read metadata file and group files
    def samples = Channel.fromPath(params.metadata)
        | splitCsv(header: true)
        | map { row -> tuple(row.Sample, row.Factor == "bg" ? file(row.File) : null, row.Factor == "clip" ? file(row.File) : null) }

    // Pass `params.db_file` as a path, ensuring Nextflow tracks it properly
    def db_file = file(params.db_file)

    def db_ch = GENERATE_DB(params.gff_file, db_file, container_pulled)

    def bg_dat_ch = PARSING_BG(db_ch, params.genome_dir, samples.filter { it[1] != null }.map { it[1] }.collect(),params.bg_f,container_pulled)
    def clip_dat_ch = PARSING_CLIP(db_ch, params.genome_dir, samples.filter { it[2] != null }.map { it[2] }.collect(),params.clip_f,container_pulled)

    RUN_OMNICLIP(db_ch, bg_dat_ch, clip_dat_ch, params.output_dir, params.max_it, params.nb_cores, container_pulled)
}
