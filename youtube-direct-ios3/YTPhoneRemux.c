#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/mathematics.h>
#include <stdio.h>
int YTRemuxPhoneVideo(const char *inputPath,const char *outputPath) {
    AVFormatContext *input=NULL,*output=NULL; int result=-1,packets=0;
    av_register_all();
    if(avformat_open_input(&input,inputPath,NULL,NULL)<0 || avformat_find_stream_info(input,NULL)<0) goto finish;
    // Never allow a server-selected 360p stream to sneak into the phone fallback.
    if(input->nb_streams!=1 || input->streams[0]->codec->codec_type!=AVMEDIA_TYPE_VIDEO ||
       input->streams[0]->codec->codec_id!=AV_CODEC_ID_H264 ||
       input->streams[0]->codec->width<=0 || input->streams[0]->codec->height<=0 ||
       input->streams[0]->codec->width>256 || input->streams[0]->codec->height>144) goto finish;
    if(avformat_alloc_output_context2(&output,NULL,"mp4",outputPath)<0 || !output) goto finish;
    AVStream *stream=avformat_new_stream(output,NULL); if(!stream) goto finish;
    if(avcodec_copy_context(stream->codec,input->streams[0]->codec)<0) goto finish;
    stream->codec->codec_tag=0; stream->time_base=input->streams[0]->time_base;
    if(output->oformat->flags&AVFMT_GLOBALHEADER) stream->codec->flags|=AV_CODEC_FLAG_GLOBAL_HEADER;
    if(avio_open(&output->pb,outputPath,AVIO_FLAG_WRITE)<0) goto finish;
    AVDictionary *options=NULL; av_dict_set(&options,"movflags","faststart",0);
    int header=avformat_write_header(output,&options); av_dict_free(&options); if(header<0) goto finish;
    AVPacket packet; int read;
    while((read=av_read_frame(input,&packet))>=0) {
        av_packet_rescale_ts(&packet,input->streams[0]->time_base,stream->time_base);
        packet.pos=-1; packet.stream_index=0;
        int wrote=av_interleaved_write_frame(output,&packet); av_packet_unref(&packet);
        if(wrote<0) goto finish; packets++;
    }
    if(read!=AVERROR_EOF || !packets || av_write_trailer(output)<0) goto finish;
    result=0;
finish:
    if(input) avformat_close_input(&input);
    if(output) { if(output->pb) avio_closep(&output->pb); avformat_free_context(output); }
    if(result<0) remove(outputPath);
    return result;
}
