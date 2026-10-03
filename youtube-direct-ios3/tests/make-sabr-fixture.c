#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <assert.h>
int main(int argc,char **argv) {
    assert(argc==3); av_register_all(); AVFormatContext *in=NULL,*out=NULL;
    assert(avformat_open_input(&in,argv[1],NULL,NULL)==0);
    assert(avformat_find_stream_info(in,NULL)>=0);
    assert(avformat_alloc_output_context2(&out,NULL,"mp4",argv[2])>=0);
    AVStream *s=avformat_new_stream(out,NULL); assert(s);
    assert(avcodec_copy_context(s->codec,in->streams[0]->codec)>=0); s->codec->codec_tag=0; s->time_base=in->streams[0]->time_base;
    assert(avio_open(&out->pb,argv[2],AVIO_FLAG_WRITE)>=0);
    AVDictionary *opts=NULL; av_dict_set(&opts,"movflags","frag_keyframe+empty_moov+default_base_moof",0);
    assert(avformat_write_header(out,&opts)>=0); av_dict_free(&opts);
    AVPacket p; while(av_read_frame(in,&p)>=0) { av_packet_rescale_ts(&p,in->streams[0]->time_base,s->time_base); p.pos=-1; assert(av_interleaved_write_frame(out,&p)>=0); av_packet_unref(&p); }
    assert(av_write_trailer(out)>=0); avio_closep(&out->pb); avformat_free_context(out); avformat_close_input(&in); return 0;
}
