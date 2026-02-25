package com.example;

import com.example.sidecar.SidecarServiceImpl;
import io.grpc.Server;
import io.grpc.netty.shaded.io.grpc.netty.NettyServerBuilder;
import io.grpc.netty.shaded.io.netty.channel.EventLoopGroup;
import io.grpc.netty.shaded.io.netty.channel.epoll.EpollEventLoopGroup;
import io.grpc.netty.shaded.io.netty.channel.epoll.EpollServerDomainSocketChannel;
import io.grpc.netty.shaded.io.netty.channel.unix.DomainSocketAddress;

import java.io.IOException;

public class BigtableSidecar {
    public static void main(String[] args) throws IOException, InterruptedException {
        if (args.length < 1) {
            System.err.println("Usage: BigtableSidecar <socket_path>");
            System.exit(1);
        }

        String socketPath = args[0];
        System.err.println("Java Sidecar: Starting gRPC server on " + socketPath);

        EventLoopGroup bossGroup = new EpollEventLoopGroup(1);
        EventLoopGroup workerGroup = new EpollEventLoopGroup();

        Server server = NettyServerBuilder.forAddress(new DomainSocketAddress(socketPath))
                .channelType(EpollServerDomainSocketChannel.class)
                .workerEventLoopGroup(workerGroup)
                .bossEventLoopGroup(bossGroup)
                .addService(new SidecarServiceImpl())
                .build();

        server.start();

        System.err.println("Java Sidecar: Server started, listening on " + socketPath);


        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            System.err.println("Java Sidecar: Shutting down...");
            server.shutdown();
            System.err.println("Java Sidecar: Shut down complete.");
        }));

        server.awaitTermination();
    }
}

